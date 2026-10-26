#!/usr/bin/env bash
# Turns the running FIPS VM into a reusable image: removes the per-run state, shuts the VM down and writes
# a standalone, compressed qcow2. Used by .github/workflows/fips-vm-image.yml after the fips-vm action.
#
# usage: seal.sh OUTPUT.qcow2
set -euo pipefail

output=${1:?usage: seal.sh OUTPUT.qcow2}
: "${FIPS_VM_DIR:?run the fips-vm action first}"

vm() {
  ssh -i "$FIPS_VM_SSH_KEY" -p "$FIPS_VM_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o BatchMode=yes runner@127.0.0.1 "$@"
}

# Next boot is a new instance: cloud-init runs again with the new job's SSH key, and the VM gets new
# SSH host keys and a new machine id. This removes the SSH key, so the same session schedules the shutdown.
vm 'sudo bash -s' <<'SCRIPT'
set -euo pipefail
docker system prune --all --force --volumes >/dev/null
dnf clean all >/dev/null
rm -rf /home/runner/.m2 /tmp/* /var/tmp/*
rm -f /home/runner/.ssh/authorized_keys /home/runner/.bash_history /root/.bash_history
cloud-init clean --logs --machine-id
fstrim --all || true
systemd-run --quiet --on-active=3 /usr/bin/systemctl poweroff
SCRIPT

pid=$(sudo cat "$FIPS_VM_DIR/qemu.pid")
for _ in $(seq 120); do
  sudo kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if sudo kill -0 "$pid" 2>/dev/null; then
  echo "::error::The VM didn't shut down."
  exit 1
fi

qemu-img convert -c -O qcow2 "$FIPS_VM_DIR/disk.qcow2" "$output"
qemu-img info "$output"
