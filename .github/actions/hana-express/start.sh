#!/usr/bin/env bash
# Starts SAP HANA, express edition in Docker with TLS that a client can verify (INT-2383).
#
# The image creates its own self-signed server certificate for the container's host name. This script
# replaces it with one for localhost, signed by a CA it makes here, so a client can connect to
# localhost with full certificate validation. Writes the CA, a PKCS12 trust store and connection
# details to the work folder, and to GITHUB_OUTPUT when it runs in a workflow.
#
# Needs Docker on Linux x86_64, about 12 GB of free memory, openssl and keytool.
#
# Settings (environment):
#   HANA_AGREE_TO_SAP_LICENSE  must be true: the image only starts when SAP's license is accepted
#   HANA_IMAGE                 the image, by default the saplabs/hanaexpress release pinned by digest
#   HANA_PASSWORD              password of SYSTEM; generated when empty
#   HANA_EXTRA_SAN             more names for the certificate, such as DNS:db.test,IP:192.0.2.10
#   HANA_NAME                  container name, hana-express by default
#   HANA_WORK_DIR              where the certificates and passwords go; a temporary folder by default
#   HANA_TIMEOUT_MINUTES       how long to wait for the database, 20 by default
set -euo pipefail

step() { echo "==> $*"; }
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[ "${HANA_AGREE_TO_SAP_LICENSE:-false}" = true ] ||
  fail "Set agree-to-sap-license to true to accept SAP's license for SAP HANA, express edition."

image=${HANA_IMAGE:-saplabs/hanaexpress:2.00.088.00.20251110.1@sha256:432be2785506e97cefc413f495393fc22fcdda034c2c80db2f0f88efeb16dfaf}
name=${HANA_NAME:-hana-express}
work=${HANA_WORK_DIR:-${RUNNER_TEMP:-$(mktemp -d)}/hana-express}
timeout_min=${HANA_TIMEOUT_MINUTES:-20}
# The host name inside the container. HANA's own certificate is issued to it.
host=hxehost
# Names in the certificate: localhost for the runner, and 10.0.2.2, the runner's address as seen from the
# FIPS VM (fips-vm action).
san="DNS:localhost,DNS:$host,IP:127.0.0.1,IP:10.0.2.2${HANA_EXTRA_SAN:+,$HANA_EXTRA_SAN}"
# SQL ports of instance 90: 39017 is the system database, 39041 the tenant database HXE.
system_port=39017
tenant_port=39041

for tool in docker openssl keytool jq; do
  command -v "$tool" >/dev/null || fail "$tool is not installed."
done
[ "$(uname -m)" = x86_64 ] || fail "SAP HANA, express edition runs on x86_64 only."

mkdir -p "$work/mounts" "$work/tls"

password=${HANA_PASSWORD:-}
if [ -z "$password" ]; then
  # HANA wants 8 or more characters with upper case, lower case and a digit.
  password="Hx$(openssl rand -hex 12)9A"
fi
[ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$password"

# The image reads the password from a file that its user hxeadm (uid 12000, gid 79) owns.
# jq writes the JSON, so a password with " or \ in it stays valid JSON.
jq -n --arg p "$password" '{master_password: $p}' >"$work/mounts/passwords.json"
chmod 600 "$work/mounts/passwords.json"
sudo chown -R 12000:79 "$work/mounts"

step "Starting $image"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --hostname "$host" \
  -p "$system_port:$system_port" -p "$tenant_port:$tenant_port" \
  -v "$work/mounts:/hana/mounts" \
  --ulimit nofile=1048576:1048576 \
  --sysctl kernel.shmmax=1073741824 \
  --sysctl net.ipv4.ip_local_port_range='40000 60999' \
  --sysctl kernel.shmmni=4096 \
  --sysctl kernel.shmall=8388608 \
  "$image" --passwords-url file:///hana/mounts/passwords.json --agree-to-sap-license >/dev/null

started=$SECONDS
# grep without -q reads to the end: under pipefail, -q can kill docker logs with SIGPIPE after the match.
until docker logs "$name" 2>&1 | grep 'Startup finished' >/dev/null; do
  [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || {
    docker logs --tail 60 "$name" >&2 || true
    fail "The container stopped before the database started."
  }
  [ $((SECONDS - started)) -lt $((timeout_min * 60)) ] || {
    docker logs --tail 60 "$name" >&2 || true
    fail "The database did not start in $timeout_min minutes."
  }
  sleep 10
done
step "The database started in $((SECONDS - started)) seconds"

# The image no longer needs the password file.
sudo rm -f "$work/mounts/passwords.json"

step "Making a CA and a server certificate for $san"
tls=$work/tls
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
  -subj "/O=Liquibase test/CN=hana-express test CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$tls/ca.key" -out "$tls/ca.pem" 2>/dev/null
openssl req -newkey rsa:3072 -sha256 -nodes -subj "/O=Liquibase test/CN=localhost" \
  -keyout "$tls/server.key" -out "$tls/server.csr" 2>/dev/null
printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san" >"$tls/server.ext"
openssl x509 -req -in "$tls/server.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial \
  -sha256 -days 30 -extfile "$tls/server.ext" -out "$tls/server.pem" 2>/dev/null
# The CA key has done its job: nothing else can be signed with this CA.
rm -f "$tls/ca.key" "$tls/server.csr" "$tls/server.ext" "$tls/ca.srl"

step "Installing the server certificate in HANA"
docker exec "$name" mkdir -p /tmp/tls
for f in server.key server.pem ca.pem; do docker cp -q "$tls/$f" "$name:/tmp/tls/$f"; done
docker exec -u 0 "$name" chown -R 12000:79 /tmp/tls
# HANA reads its TLS key and certificate from sapsrv.pse in SECUDIR. A login shell sets SECUDIR.
# The new PSE is built beside it and kept as sapsrv.pse.new.
docker exec "$name" bash -lc '
  set -e
  cd "$SECUDIR"
  cp sapsrv.pse sapsrv.pse.orig
  rm -f sapsrv.pse.new
  sapgenpse import_p8 -p "$SECUDIR/sapsrv.pse.new" -x "" -c /tmp/tls/server.pem -r /tmp/tls/ca.pem /tmp/tls/server.key
  rm -rf /tmp/tls
'
rm -f "$tls/server.key"

# Puts the new PSE in place with a rename, so sapsrv.pse is never missing or half written. When HANA can't load
# sapsrv.pse it falls back to a certificate of its own ("SAP HANA ClientPKI") and keeps it: that happened once in
# eight starts while the file was removed and rewritten in place.
install_pse() {
  docker exec "$name" bash -lc 'cd "$SECUDIR" && cp sapsrv.pse.new sapsrv.pse.tmp && mv -f sapsrv.pse.tmp sapsrv.pse'
}
install_pse

# HANA picks up the new file by itself. Wait until both ports serve the new certificate. If they don't after a
# minute, put the file in place again: a new file is what makes HANA read it.
verify() {
  openssl s_client -connect "localhost:$1" -servername localhost -CAfile "$tls/ca.pem" \
    -verify_return_error -verify_hostname localhost </dev/null >"$work/s_client-$1.txt" 2>&1
}
started=$SECONDS
reinstalled=$SECONDS
until verify "$tenant_port" && verify "$system_port"; do
  [ $((SECONDS - started)) -lt 300 ] || {
    tail -n 30 "$work/s_client-$tenant_port.txt" >&2 || true
    fail "HANA did not serve the new certificate in 5 minutes."
  }
  if [ $((SECONDS - reinstalled)) -ge 60 ]; then
    served=$(grep -m1 -E '^ *0 s:' "$work/s_client-$tenant_port.txt" | sed 's/^ *0 s://' || true)
    step "HANA still serves another certificate (${served:-none}): putting the new one in place again"
    install_pse
    reinstalled=$SECONDS
  fi
  sleep 5
done
step "HANA serves the new certificate ($(grep -m1 -E 'Protocol|New,' "$work/s_client-$tenant_port.txt" | xargs))"

truststore=$tls/truststore.p12
truststore_password=changeit
rm -f "$truststore"
keytool -importcert -noprompt -alias hana-express-ca -file "$tls/ca.pem" \
  -keystore "$truststore" -storetype PKCS12 -storepass "$truststore_password" >/dev/null 2>&1

# Public files: other users, such as the FIPS VM's, may read them.
chmod 755 "$work" "$tls"
chmod 644 "$tls/ca.pem" "$tls/server.pem" "$truststore"

tls_params="encrypt=true&validateCertificate=true&trustStore=$truststore&trustStorePassword=$truststore_password&trustStoreType=PKCS12"
url="jdbc:sap://localhost:$tenant_port/?$tls_params"
system_url="jdbc:sap://localhost:$system_port/?$tls_params"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "url=$url"
    echo "system-url=$system_url"
    echo "host=localhost"
    echo "port=$tenant_port"
    echo "system-port=$system_port"
    echo "username=SYSTEM"
    echo "password=$password"
    echo "ca-cert=$tls/ca.pem"
    echo "truststore=$truststore"
    echo "truststore-password=$truststore_password"
    echo "container=$name"
    echo "image=$(docker inspect -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "$image")"
  } >>"$GITHUB_OUTPUT"
fi
step "Ready: $url (user SYSTEM)"
