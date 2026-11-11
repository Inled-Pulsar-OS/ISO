#!/bin/bash
# ==============================================================================
# Pulsar OS - Fast QEMU / KVM UEFI VM Runner
# ==============================================================================
# Usage: ./run-qemu.sh [path/to/pulsaros.iso]
#
# ISO resolution order:
#   1. First argument
#   2. $ISO environment variable
#   3. Newest pulsaros-*.iso under ./build (next to this script)
#
# Optional environment overrides:
#   RAM=5G  CPUS=4  DISK_SIZE=25G
#   VM_DIR=~/.local/share/pulsar-vm   (persistent disk + UEFI variables)
#   FRESH=1                           (recreate the disk and UEFI variables)
#   NO_KVM=1                          (run without KVM acceleration)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- ISO ----------------------------------------------------------------------
ISO="${1:-${ISO:-}}"
if [ -z "$ISO" ]; then
    # Newest ISO by modification time; no dependency on any user's home directory.
    ISO=$(find "$SCRIPT_DIR/build" -maxdepth 1 -name 'pulsaros-*.iso' -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | head -n 1 | cut -d' ' -f2- || true)
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "❌ No ISO file found. Provide one: $0 /path/to/pulsaros.iso (or set ISO=...)" >&2
    exit 1
fi
if [ ! -r "$ISO" ]; then
    echo "❌ ISO is not readable by $(id -un): $ISO" >&2
    exit 1
fi
ISO="$(realpath "$ISO")"

# --- Tools --------------------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null || { echo "❌ qemu-system-x86_64 not found. Install qemu-full (Arch) or qemu-system-x86 (Debian/Ubuntu)." >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "❌ qemu-img not found. Install qemu-full (Arch) or qemu-utils (Debian/Ubuntu)." >&2; exit 1; }

# --- UEFI firmware --------------------------------------------------------------
# Preferred: split CODE + VARS pair, so UEFI variables persist between boots.
#   Arch    edk2-ovmf: /usr/share/edk2/x64/OVMF_CODE.4m.fd + OVMF_VARS.4m.fd
#   Debian  ovmf:      /usr/share/OVMF/OVMF_CODE_4M.fd + OVMF_VARS_4M.fd
#                      (bookworm also ships the older 2M OVMF_CODE.fd + OVMF_VARS.fd)
#   Fedora  edk2-ovmf: /usr/share/edk2/ovmf/OVMF_CODE.fd + OVMF_VARS.fd
# Fallback: a single OVMF.fd image via -bios (Debian /usr/share/ovmf/OVMF.fd);
#   it works, but UEFI variables are not saved.
# OVMF_DIRS="dir1 dir2" overrides the split-pair search path.
OVMF_CODE=""
OVMF_VARS_TEMPLATE=""
OVMF_BIOS=""
read -r -a OVMF_SEARCH <<< "${OVMF_DIRS:-/usr/share/edk2/x64 /usr/share/edk2-ovmf/x64 /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/ovmf/x64 /usr/share/ovmf}"
for dir in "${OVMF_SEARCH[@]}"; do
    for code in OVMF_CODE.4m.fd OVMF_CODE_4M.fd OVMF_CODE.fd; do
        vars="${code/CODE/VARS}"
        if [ -f "$dir/$code" ] && [ -f "$dir/$vars" ]; then
            OVMF_CODE="$dir/$code"
            OVMF_VARS_TEMPLATE="$dir/$vars"
            break 2
        fi
    done
done

if [ -z "$OVMF_CODE" ]; then
    for f in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd /usr/share/OVMF/OVMF.fd \
             /usr/share/edk2-ovmf/x64/OVMF.fd /usr/share/edk2/x64/OVMF.4m.fd; do
        if [ -f "$f" ]; then
            OVMF_BIOS="$f"
            break
        fi
    done
fi

if [ -z "$OVMF_CODE" ] && [ -z "$OVMF_BIOS" ]; then
    echo "❌ OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)." >&2
    exit 1
fi

# --- Persistent VM state (not /tmp, so it survives reboots) --------------------
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pulsar-vm}"
mkdir -p "$VM_DIR"
TEST_DISK="$VM_DIR/disk.qcow2"
OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

if [ "${FRESH:-0}" = "1" ]; then
    rm -f "$TEST_DISK" "$OVMF_VARS"
fi
# An empty disk file (interrupted qemu-img, or a stub) is not a qcow2 image: recreate it.
# Anything non-empty that is not qcow2 is never deleted, only reported.
if [ -f "$TEST_DISK" ] && [ ! -s "$TEST_DISK" ]; then
    echo "⚠️  $TEST_DISK is empty: recreating it." >&2
    rm -f "$TEST_DISK"
elif [ -s "$TEST_DISK" ] && ! qemu-img info "$TEST_DISK" 2>/dev/null | grep -q '^file format: qcow2'; then
    echo "❌ $TEST_DISK is not a qcow2 image. Move it away or run with FRESH=1." >&2
    exit 1
fi
if [ ! -f "$TEST_DISK" ]; then
    echo "📦 Creating virtual ${DISK_SIZE:-25G} disk at $TEST_DISK for installer / recovery test..."
    qemu-img create -f qcow2 "$TEST_DISK" "${DISK_SIZE:-25G}" >/dev/null
fi
if [ -n "$OVMF_CODE" ]; then
    # A VARS file from a different firmware build (Debian 2M vs 4M) makes QEMU refuse to start.
    if [ -f "$OVMF_VARS" ] && [ "$(stat -c %s "$OVMF_VARS")" != "$(stat -c %s "$OVMF_VARS_TEMPLATE")" ]; then
        echo "⚠️  $OVMF_VARS does not match the installed firmware (size changed): recreating it." >&2
        rm -f "$OVMF_VARS"
    fi
    [ -f "$OVMF_VARS" ] || cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
fi

# --- Acceleration --------------------------------------------------------------
if [ "${NO_KVM:-0}" != "1" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
else
    echo "⚠️  /dev/kvm not usable: running without KVM (slow). On Debian/Ubuntu add yourself to the 'kvm' group." >&2
    ACCEL=(-cpu max)
fi

echo "🚀 Booting Pulsar OS ISO in QEMU (UEFI OVMF): $ISO"
if [ -n "$OVMF_CODE" ]; then
    echo "   firmware: $OVMF_CODE"
    UEFI=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
          -drive if=pflash,format=raw,file="$OVMF_VARS")
else
    echo "   firmware: $OVMF_BIOS (single image: UEFI variables are not saved)"
    UEFI=(-bios "$OVMF_BIOS")
fi
echo "   disk:     $TEST_DISK"

exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "${RAM:-5G}" \
    -smp "${CPUS:-4}" \
    "${UEFI[@]}" \
    -drive file="$TEST_DISK",if=virtio,format=qcow2 \
    -drive file="$ISO",media=cdrom,readonly=on \
    -boot menu=on \
    -vga virtio \
    -device virtio-tablet-pci \
    -nic user,model=virtio-net-pci \
    -display default,show-cursor=on
