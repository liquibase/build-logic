#!/usr/bin/env bash
# Boots a FIPS-mode AlmaLinux 9 VM on this runner with KVM and shares the runner's work directory with it
# at the same path, so steps that use `shell: fips-run {0}` see the same files. Called by action.yml.
#
# Inputs (environment): FIPS_VM_IMAGE, FIPS_VM_CPUS, FIPS_VM_MEMORY_MB, FIPS_VM_DISK_SIZE, FIPS_VM_TOKEN.
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
provision_script="$action_dir/../../../fips/provision.sh"
share=$(dirname "$RUNNER_TEMP")
ssh_port=2222
alma_url=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images
alma_image=AlmaLinux-9-GenericCloud-latest.x86_64.qcow2

fail() {
  echo "::error::$*"
  exit 1
}

# Keep the VM disks off the shared work directory. /mnt is the large scratch disk on GitHub-hosted runners.
vm_dir=/mnt/fips-vm
sudo mkdir -p "$vm_dir" && sudo chown "$(id -u):$(id -g)" "$vm_dir"

echo "::group::Check the runner"
[ -e /dev/kvm ] || fail "This runner has no /dev/kvm, so it can't start the FIPS VM. Use a GitHub-hosted Linux x64 runner, for example ubuntu-latest."
[ "$(uname -m)" = x86_64 ] || fail "The FIPS VM needs an x86_64 runner, this one is $(uname -m)."
[ "$(id -u)" = 1001 ] || echo "::warning::The runner user has uid $(id -u), not 1001. Files created in the VM may get a different owner."
echo "::endgroup::"

echo "::group::Install QEMU and virtiofsd"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  qemu-system-x86 qemu-utils cloud-image-utils virtiofsd >/dev/null
virtiofsd_bin=$(command -v virtiofsd || echo /usr/libexec/virtiofsd)
[ -x "$virtiofsd_bin" ] || fail "virtiofsd is not installed."
echo "::endgroup::"

echo "::group::Get the VM disk"
if [ -n "$FIPS_VM_IMAGE" ]; then
  echo "$FIPS_VM_TOKEN" | oras login ghcr.io -u fips-vm --password-stdin >/dev/null
  oras pull --output "$vm_dir" "$FIPS_VM_IMAGE"
  base="$vm_dir/fips-vm.qcow2"
  image_ref="$FIPS_VM_IMAGE@$(oras resolve "$FIPS_VM_IMAGE")"
else
  curl -fsSL -o "$vm_dir/$alma_image" "$alma_url/$alma_image"
  (cd "$vm_dir" && curl -fsSL "$alma_url/CHECKSUM" | grep " $alma_image\$" | sha256sum -c -)
  base="$vm_dir/$alma_image"
  image_ref="$alma_url/$alma_image (sha256:$(sha256sum "$base" | cut -d' ' -f1)), provisioned by fips/provision.sh"
fi
qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$vm_dir/disk.qcow2" "$FIPS_VM_DISK_SIZE"
echo "$image_ref"
echo "::endgroup::"

echo "::group::Write the cloud-init seed"
rm -f "$vm_dir/key" "$vm_dir/key.pub"
ssh-keygen -q -t ed25519 -N '' -C fips-vm -f "$vm_dir/key"
uid=$(id -u)
cat > "$vm_dir/user-data" <<EOF
#cloud-config
bootcmd:
  - [sh, -c, "id runner >/dev/null 2>&1 || useradd -m -u $uid runner"]
  - [sh, -c, "mkdir -p '$share' && (mountpoint -q '$share' || mount -t virtiofs work '$share')"]
users:
  - name: runner
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["$(cat "$vm_dir/key.pub")"]
EOF
if [ -z "$FIPS_VM_IMAGE" ]; then
  # No prebuilt image: provision the cloud image now, then reboot into FIPS mode.
  cat >> "$vm_dir/user-data" <<EOF
write_files:
  - path: /usr/local/sbin/fips-vm-provision
    permissions: "0755"
    encoding: b64
    content: $(base64 -w0 "$provision_script")
runcmd:
  - [env, "RUNNER_UID=$uid", /usr/local/sbin/fips-vm-provision]
power_state:
  mode: reboot
  condition: test -f /var/lib/fips-vm/provisioned
EOF
fi
printf 'instance-id: fips-vm-%s\nlocal-hostname: fips-vm\n' "$(date +%s)$RANDOM" > "$vm_dir/meta-data"
cloud-localds "$vm_dir/seed.iso" "$vm_dir/user-data" "$vm_dir/meta-data"
echo "::endgroup::"

echo "::group::Boot the VM"
cpus=${FIPS_VM_CPUS:-$(nproc)}
memory_mb=${FIPS_VM_MEMORY_MB:-$(($(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo) * 3 / 4))}
sock="$vm_dir/virtiofs.sock"
rm -f "$sock"
nohup sudo "$virtiofsd_bin" --socket-path="$sock" --shared-dir="$share" --cache=auto \
  </dev/null >"$vm_dir/virtiofsd.log" 2>&1 &
for _ in $(seq 50); do
  [ -S "$sock" ] && break
  sleep 0.2
done
[ -S "$sock" ] || { cat "$vm_dir/virtiofsd.log"; fail "virtiofsd didn't start."; }

sudo qemu-system-x86_64 -name fips-vm -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$memory_mb" \
  -object memory-backend-memfd,id=mem,size="${memory_mb}M",share=on -numa node,memdev=mem \
  -chardev socket,id=vfs,path="$sock" -device vhost-user-fs-pci,chardev=vfs,tag=work \
  -drive file="$vm_dir/disk.qcow2",if=virtio,discard=unmap \
  -drive file="$vm_dir/seed.iso",if=virtio,format=raw,readonly=on \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${ssh_port}-:22 \
  -display none -serial file:"$vm_dir/serial.log" -pidfile "$vm_dir/qemu.pid" -daemonize
echo "Started with $cpus CPUs and $memory_mb MB of memory."
echo "::endgroup::"

ssh_opts=(-i "$vm_dir/key" -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5)
# shellcheck disable=SC2029 # the commands are meant to expand on the runner
vm() { ssh "${ssh_opts[@]}" runner@127.0.0.1 "$@"; }
show_logs() {
  echo "::group::VM serial console (last 100 lines)"
  sudo tail -n 100 "$vm_dir/serial.log" || true
  echo "::endgroup::"
  echo "::group::cloud-init output (last 100 lines)"
  vm 'sudo tail -n 100 /var/log/cloud-init-output.log' 2>/dev/null || echo "Not reachable over SSH."
  echo "::endgroup::"
}

echo "::group::Wait for the VM"
timeout_s=$([ -n "$FIPS_VM_IMAGE" ] && echo 600 || echo 1800)
deadline=$((SECONDS + timeout_s))
until vm "test \"\$(cat /proc/sys/crypto/fips_enabled)\" = 1 && mountpoint -q '$share'" 2>/dev/null; do
  if ! sudo kill -0 "$(cat "$vm_dir/qemu.pid")" 2>/dev/null; then
    show_logs
    fail "The VM stopped while booting."
  fi
  if vm 'cloud-init status 2>/dev/null | grep -q "status: error" && ! test -f /var/lib/fips-vm/provisioned' 2>/dev/null; then
    show_logs
    fail "Provisioning the VM failed."
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    show_logs
    fail "The VM wasn't in FIPS mode after $((timeout_s / 60)) minutes."
  fi
  sleep 10
done
vm 'cloud-init status --wait >/dev/null 2>&1 || true'
echo "Ready after ${SECONDS}s."
echo "::endgroup::"

echo "::group::FIPS status"
# shellcheck disable=SC2016 # expanded in the VM
status=$(vm 'echo "fips_enabled: $(cat /proc/sys/crypto/fips_enabled)"
  echo "fips-mode-setup: $(sudo fips-mode-setup --check 2>&1 | tail -n 1)"
  echo "crypto policy: $(update-crypto-policies --show)"
  echo "os: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
  echo "java: $(java -version 2>&1 | head -n 1)"
  echo "docker: $(docker --version)"')
printf 'image: %s\n%s\n' "$image_ref" "$status" | tee "$vm_dir/status.txt"
{
  echo "### FIPS VM"
  echo
  echo '```'
  cat "$vm_dir/status.txt"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
echo "::endgroup::"

sudo install -m 0755 "$action_dir/fips-run" /usr/local/bin/fips-run
{
  echo "FIPS_VM_DIR=$vm_dir"
  echo "FIPS_VM_SSH_KEY=$vm_dir/key"
  echo "FIPS_VM_SSH_PORT=$ssh_port"
} >> "$GITHUB_ENV"
echo "image=$image_ref" >> "$GITHUB_OUTPUT"
