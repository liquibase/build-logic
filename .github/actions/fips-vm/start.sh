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

# One visible line per phase. Groups would hide progress in the live log.
step() { echo "==> $*"; }

# Keep the VM disks off the shared work directory. /mnt is the large scratch disk on GitHub-hosted runners.
vm_dir=/mnt/fips-vm
sudo mkdir -p "$vm_dir" && sudo chown "$(id -u):$(id -g)" "$vm_dir"

step "Checking the runner"
[ -e /dev/kvm ] || fail "This runner has no /dev/kvm, so it can't start the FIPS VM. Use a Linux x64 runner with KVM, for example ubuntu-latest or blacksmith-4vcpu-ubuntu-2404."
[ "$(uname -m)" = x86_64 ] || fail "The FIPS VM needs an x86_64 runner, this one is $(uname -m)."
[ "$(id -u)" = 1001 ] || echo "::warning::The runner user has uid $(id -u), not 1001. Files created in the VM may get a different owner."

step "Installing QEMU and virtiofsd"
# Hosted runners carry many third-party apt repos and slow dpkg triggers: read only the Ubuntu archive,
# and skip man-db and needrestart.
apt_opts=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  apt_sources=$(mktemp -d)
  cp /etc/apt/sources.list.d/ubuntu.sources "$apt_sources/"
  apt_opts+=(-o Dir::Etc::SourceList=/dev/null -o "Dir::Etc::SourceParts=$apt_sources")
fi
sudo rm -f /var/lib/man-db/auto-update
t=$SECONDS
sudo apt-get "${apt_opts[@]}" update -qq
t_update=$((SECONDS - t))
t=$SECONDS
sudo NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y -qq --no-install-recommends \
  qemu-system-x86 qemu-utils cloud-image-utils virtiofsd >/dev/null
echo "    apt-get update ${t_update}s, install $((SECONDS - t))s"
virtiofsd_bin=$(command -v virtiofsd || echo /usr/libexec/virtiofsd)
[ -x "$virtiofsd_bin" ] || fail "virtiofsd is not installed."

if [ -n "$FIPS_VM_IMAGE" ]; then
  step "Downloading the FIPS VM image $FIPS_VM_IMAGE"
  t=$SECONDS
  "$action_dir/install-oras.sh"
  echo "$FIPS_VM_TOKEN" | oras login ghcr.io -u fips-vm --password-stdin >/dev/null
  oras pull --output "$vm_dir" "$FIPS_VM_IMAGE" >/dev/null
  base="$vm_dir/fips-vm.qcow2"
  image_ref="$FIPS_VM_IMAGE@$(oras resolve "$FIPS_VM_IMAGE")"
  echo "    $(du -h "$base" | cut -f1) in $((SECONDS - t))s"
else
  step "Downloading the AlmaLinux 9 cloud image (no prebuilt image requested)"
  curl -fsSL -o "$vm_dir/$alma_image" "$alma_url/$alma_image"
  (cd "$vm_dir" && curl -fsSL "$alma_url/CHECKSUM" | grep " $alma_image\$" | sha256sum -c -)
  base="$vm_dir/$alma_image"
  image_ref="$alma_url/$alma_image (sha256:$(sha256sum "$base" | cut -d' ' -f1)), provisioned by fips/provision.sh"
fi
qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$vm_dir/disk.qcow2" "$FIPS_VM_DISK_SIZE"
echo "    $image_ref"

rm -f "$vm_dir/key" "$vm_dir/key.pub"
# ECDSA, not Ed25519: OpenSSH on RHEL 9 refuses Ed25519 keys in FIPS mode.
ssh-keygen -q -t ecdsa -b 384 -N '' -C fips-vm -f "$vm_dir/key"
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

cpus=${FIPS_VM_CPUS:-$(nproc)}
memory_mb=${FIPS_VM_MEMORY_MB:-$(($(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo) * 3 / 4))}
step "Booting the VM with $cpus CPUs and $memory_mb MB of memory"
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
qemu_pid=$(sudo cat "$vm_dir/qemu.pid")

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

# The last readable line of the VM console, to show what the VM is doing. The SSH sessions that check on
# the VM are left out, since they are this script.
console_tail() {
  sudo tail -c 8000 "$vm_dir/serial.log" 2>/dev/null | tr '\r' '\n' |
    sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/[[:cntrl:]]//g' |
    grep -vE '^[[:space:]]*$|Session [0-9]+ of User|session-[0-9]+\.scope' | tail -n 1 | cut -c1-140
}

if [ -n "$FIPS_VM_IMAGE" ]; then
  step "Waiting for the VM to boot in FIPS mode"
else
  step "Waiting for the VM: it installs Docker, Java and Maven, then reboots in FIPS mode (about 10 minutes)"
fi
timeout_s=$([ -n "$FIPS_VM_IMAGE" ] && echo 600 || echo 1800)
started=$SECONDS
last_report=$SECONDS
while :; do
  if ! state=$(vm "echo fips=\$(cat /proc/sys/crypto/fips_enabled)" \
    "provisioned=\$(test -f /var/lib/fips-vm/provisioned && echo 1 || echo 0)" \
    "mounted=\$(mountpoint -q '$share' && echo 1 || echo 0)" \
    "cloudinit=\$(cloud-init status 2>/dev/null | sed -n 's/^status: //p')" 2>"$vm_dir/ssh.err"); then
    state=unreachable
  fi
  case $state in *fips=1*mounted=1*) break ;; esac

  if ! sudo kill -0 "$qemu_pid" 2>/dev/null; then
    show_logs
    fail "The VM stopped while booting."
  fi
  case $state in *provisioned=0*cloudinit=error*)
    show_logs
    fail "Installing the software in the VM failed. See the cloud-init output above."
    ;;
  esac
  elapsed=$((SECONDS - started))
  if [ "$elapsed" -ge "$timeout_s" ]; then
    show_logs
    fail "The VM wasn't in FIPS mode after $((timeout_s / 60)) minutes."
  fi

  if [ $((SECONDS - last_report)) -ge 20 ]; then
    last_report=$SECONDS
    case $state in
      unreachable) phase="waiting for SSH ($(tr -d '\r' < "$vm_dir/ssh.err" | tail -n 1 | cut -c1-60))" ;;
      *fips=0*provisioned=0*) phase="installing Docker, Java and Maven" ;;
      *fips=0*provisioned=1*) phase="rebooting in FIPS mode" ;;
      *) phase="mounting the work folder" ;;
    esac
    printf '    %2dm%02ds  %-34s console: %s\n' $((elapsed / 60)) $((elapsed % 60)) "$phase" "$(console_tail)"
  fi
  sleep 5
done
vm 'cloud-init status --wait >/dev/null 2>&1 || true'
elapsed=$((SECONDS - started))
step "VM ready in FIPS mode after $((elapsed / 60))m$((elapsed % 60))s"

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

sudo install -m 0755 "$action_dir/fips-run" /usr/local/bin/fips-run
{
  echo "FIPS_VM_DIR=$vm_dir"
  echo "FIPS_VM_SSH_KEY=$vm_dir/key"
  echo "FIPS_VM_SSH_PORT=$ssh_port"
} >> "$GITHUB_ENV"
echo "image=$image_ref" >> "$GITHUB_OUTPUT"
