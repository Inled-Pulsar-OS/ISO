#!/bin/bash
# ==============================================================================
# Pulsar OS - Fast QEMU / KVM UEFI VM Runner
# ==============================================================================
ISO="${1}"
if [ -z "$ISO" ]; then
    ISO=$(find /home/jaime/Documentos/pulsar/ISO/build -name "pulsaros-*.iso" 2>/dev/null | head -n 1)
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "❌ No ISO file found. Provide one as argument: ./run-qemu.sh /path/to/pulsaros.iso"
    exit 1
fi

echo "🚀 Booting Pulsar OS ISO in QEMU (KVM + UEFI OVMF): $ISO"

# Find OVMF firmware
OVMF_PATH=""
for p in \
    "/usr/share/edk2/x64/OVMF.4m.fd" \
    "/usr/share/edk2-ovmf/x64/OVMF.fd" \
    "/usr/share/ovmf/x64/OVMF.fd" \
    "/usr/share/OVMF/OVMF.fd"; do
    if [ -f "$p" ]; then
        OVMF_PATH="$p"
        break
    fi
done

if [ -z "$OVMF_PATH" ]; then
    echo "❌ OVMF firmware not found. Please install edk2-ovmf."
    exit 1
fi

# Create a temporary virtual hard disk (20GB sparse) for testing installation & recovery
TEST_DISK="/tmp/pulsar-test-disk.qcow2"
if [ ! -f "$TEST_DISK" ]; then
    echo "📦 Creating virtual 25GB disk at $TEST_DISK for installer / recovery test..."
    qemu-img create -f qcow2 "$TEST_DISK" 25G
fi

qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -cpu host \
    -bios "$OVMF_PATH" \
    -drive file="$TEST_DISK",if=virtio,format=qcow2 \
    -cdrom "$ISO" \
    -boot menu=on \
    -vga virtio \
    -device virtio-tablet-pci \
    -net nic,model=virtio -net user \
    -display default,show-cursor=on
