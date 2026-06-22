#!/bin/bash
# ==============================================================================
# Pulsar OS - QEMU Tester (ISO Infrastructure)
# ==============================================================================
# Este script lanza una máquina virtual de QEMU usando directamente el chroot
# compilado (build/rootfs-target) como sistema de archivos a través de 9pfs.
# No requiere empaquetar en una ISO, lo que hace el testeo instantáneo.
# ==============================================================================

set -e

ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$(realpath -m "$ISO_DIR/build/rootfs-target")"

if [ ! -d "$ROOTFS/etc" ]; then
    echo "❌ Error: No existe el rootfs en: $ROOTFS"
    echo "Ejecuta primero: ./build-iso.sh"
    exit 1
fi

# 1. Buscar Kernel e Initrd de forma dinámica dentro de /boot/
KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | head -n 1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* 2>/dev/null | head -n 1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    echo "❌ Error: No se encontró kernel o initrd en: $ROOTFS/boot/"
    exit 1
fi

# 2. Limpieza preventiva de puertos y procesos de QEMU anteriores
echo "🧹 Liberando procesos anteriores de QEMU..."
pkexec fuser -k 5900/tcp 2>/dev/null || true
sleep 0.5

# 3. Detección automática de la arquitectura del Host
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)
        QEMU_BIN="qemu-system-x86_64"
        ACCEL="-enable-kvm -cpu host"
        CONSOLE="tty0 console=ttyS0"
        ;;
    aarch64|arm64)
        QEMU_BIN="qemu-system-aarch64"
        CONSOLE="ttyAMA0"
        # En hosts ARM (Apple Silicon / Raspberry Pi), usamos KVM si existe
        if [ -e /dev/kvm ]; then
            ACCEL="-enable-kvm -cpu host"
        else
            ACCEL="-cpu max"
        fi
        ACCEL="$ACCEL -M virt -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        ;;
    *)
        QEMU_BIN="qemu-system-x86_64"
        ACCEL=""
        CONSOLE="tty0"
        ;;
esac

echo "🖥️  Iniciando máquina virtual QEMU ($QEMU_BIN)..."
echo "📂 Chroot Target: $ROOTFS"
echo "🐧 Kernel: $(basename "$KERNEL")"
echo "📦 Initrd: $(basename "$INITRD")"

# 4. Lanzamiento de QEMU con soporte GPU acelerado (VirGL) y montaje del chroot en vivo
pkexec env \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="$XAUTHORITY" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    __NV_PRIME_RENDER_OFFLOAD=1 \
    __GLX_VENDOR_LIBRARY_NAME=nvidia \
    "$QEMU_BIN" \
    -m 4G \
    -smp 4 \
    $ACCEL \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "root=rootfs rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=262144 console=$CONSOLE quiet splash plymouth.ignore-serial-consoles fbcon=nodefer loglevel=3" \
    -fsdev local,id=rootfs,path="$ROOTFS",security_model=passthrough \
    -device virtio-9p-pci,fsdev=rootfs,mount_tag=rootfs \
    -device virtio-vga-gl \
    -display sdl,gl=on \
    -serial mon:stdio
