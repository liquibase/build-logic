#!/usr/bin/env bash
# Prepares an AlmaLinux, Rocky or RHEL 9 machine for Liquibase FIPS 140-3 testing:
# Docker CE, Red Hat OpenJDK 17 and 21, Maven 3.9 and common tools, with FIPS mode on from the next boot.
#
# The same script builds the CI image (.github/workflows/fips-vm-image.yml) and the local VM (fips/fips-vm up),
# so both environments match. Run it as root. It is safe to run again.
set -euo pipefail

MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"
RUNNER_UID="${RUNNER_UID:-1001}"

# Pick the closest mirror and download in parallel: some AlmaLinux mirrors are very slow from some networks.
for setting in fastestmirror=True max_parallel_downloads=10; do
  grep -q "^${setting%%=*}=" /etc/dnf/dnf.conf || echo "$setting" >> /etc/dnf/dnf.conf
done

dnf -y upgrade --refresh
dnf -y install dnf-plugins-core crypto-policies-scripts \
  git jq tar gzip unzip rsync which findutils procps-ng time libxml2 sqlite python3 \
  java-17-openjdk-devel java-21-openjdk-devel

# Docker CE, not Podman: the test suites depend on Docker behaviour (liquibase-pro-tests QA plan, section 6.3).
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Docker Hub images come through Google's public mirror first. Anonymous Docker Hub pulls have a low limit,
# and CI runners share IP addresses.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://mirror.gcr.io"]
}
EOF
systemctl enable docker
systemctl restart docker

# Maven 3.9, because the distribution only ships 3.6.
if [ "$(/opt/maven/bin/mvn -v 2>/dev/null | awk 'NR==1{print $3}')" != "$MAVEN_VERSION" ]; then
  url="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  curl -fsSL -o /tmp/maven.tar.gz "$url"
  echo "$(curl -fsSL "$url.sha512" | awk '{print $1}')  /tmp/maven.tar.gz" | sha512sum -c -
  rm -rf /opt/maven && mkdir -p /opt/maven
  tar -xzf /tmp/maven.tar.gz -C /opt/maven --strip-components=1
  rm -f /tmp/maven.tar.gz
fi
ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn

# Red Hat OpenJDK 21 is the default java. It switches itself to FIPS mode when the kernel is in FIPS mode.
alternatives --set java "$(readlink -f /usr/lib/jvm/java-21-openjdk/bin/java)"
alternatives --set javac "$(readlink -f /usr/lib/jvm/java-21-openjdk/bin/javac)"
cat > /etc/profile.d/fips-vm.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export JAVA_17_HOME=/usr/lib/jvm/java-17-openjdk
export JAVA_21_HOME=/usr/lib/jvm/java-21-openjdk
export MAVEN_HOME=/opt/maven
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac
EOF

# The runner user has the same uid as the GitHub runner, so files in the shared work directory keep their owner.
id runner >/dev/null 2>&1 || useradd -m -u "$RUNNER_UID" runner
usermod -aG docker runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-runner
chmod 0440 /etc/sudoers.d/90-runner

# Apple Silicon: the CPU flags show SVE, but the JVM can't use it in the VM and prints a warning on every start,
# which breaks tests that compare a command's output. Hide SVE from the VM.
if [ "$(uname -m)" = aarch64 ]; then
  grubby --update-kernel=ALL --args=arm64.nosve
fi

# FIPS mode from the next boot.
if [ "$(cat /proc/sys/crypto/fips_enabled)" != 1 ]; then
  fips-mode-setup --enable
fi

mkdir -p /var/lib/fips-vm
date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/fips-vm/provisioned
