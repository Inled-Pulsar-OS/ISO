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

# Parsear argumentos / Parse arguments
USE_ISO=false
BOOTLOADER="grub" # Default bootloader / Cargador por defecto
BRANCH="stable"
WITH_NVIDIA=false
DISTRO="debian"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            USE_ISO=true
            shift
            ;;
        --refind)
            BOOTLOADER="refind"
            shift
            ;;
        --grub)
            BOOTLOADER="grub"
            shift
            ;;
        --nvidia)
            WITH_NVIDIA=true
            shift
            ;;
        --arch)
            DISTRO="arch"
            shift
            ;;
        --debian)
            DISTRO="debian"
            shift
            ;;
        --branch|-b)
            BRANCH="$2"
            shift 2
            ;;
        *)
            echo "❌ Opción desconocida: $1"
            exit 1
            ;;
    esac
done

if [ "$BRANCH" != "stable" ] && [ "$BRANCH" != "forky" ] && [ "$BRANCH" != "rolling" ]; then
    echo "❌ Error: La rama debe ser 'stable', 'forky' o 'rolling'. Valor recibido: $BRANCH"
    exit 1
fi

if ! $USE_ISO; then
    if $WITH_NVIDIA; then
        ROOTFS="$(realpath -m "$ISO_DIR/build/rootfs-target-$BRANCH-$DISTRO-nvidia")"
    else
        ROOTFS="$(realpath -m "$ISO_DIR/build/rootfs-target-$BRANCH-$DISTRO")"
    fi

    if [ ! -d "$ROOTFS/etc" ]; then
        echo "❌ Error: No existe el rootfs en: $ROOTFS"
        if [ "$DISTRO" = "arch" ]; then
            echo "Ejecuta primero: ./build-iso.sh --arch --branch $BRANCH"
        else
            if $WITH_NVIDIA; then
                echo "Ejecuta primero: ./build-iso.sh --branch $BRANCH --nvidia"
            else
                echo "Ejecuta primero: ./build-iso.sh --branch $BRANCH"
            fi
        fi
        exit 1
    fi

    # 1. Buscar Kernel e Initrd de forma dinámica dentro de /boot/
    if [ "$DISTRO" = "arch" ]; then
        KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | head -n 1)
        INITRD=$(ls "$ROOTFS"/boot/initramfs-*.img 2>/dev/null | head -n 1)
    else
        KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | head -n 1)
        INITRD=$(ls "$ROOTFS"/boot/initrd.img-* 2>/dev/null | head -n 1)
    fi

    if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
        echo "❌ Error: No se encontró kernel o initrd en: $ROOTFS/boot/"
        exit 1
    fi

    # Asegurar permisos de lectura para el kernel e initrd
    if [ ! -r "$KERNEL" ] || [ ! -r "$INITRD" ]; then
        pkexec chmod -R a+r "$ROOTFS/boot" 2>/dev/null || sudo chmod -R a+r "$ROOTFS/boot" 2>/dev/null || true
    fi
fi

# 2. Configurar backend de pantalla y autorizaciones
if [ -n "$WAYLAND_DISPLAY" ]; then
    export GDK_BACKEND="wayland"
else
    export GDK_BACKEND="x11"
    if command -v xhost &>/dev/null; then
        xhost +local: 2>/dev/null || true
    fi
fi

# 3. Limpieza preventiva de puertos y procesos de QEMU anteriores
echo "🧹 Liberando procesos anteriores de QEMU..."
fuser -k 5900/tcp 2>/dev/null || true
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

if $USE_ISO; then
    if [ "$BOOTLOADER" = "refind" ]; then
        if $WITH_NVIDIA; then
            ISO_PATH="$ISO_DIR/build/pulsaros-${BRANCH}-${DISTRO}-refind-nvidia.iso"
        else
            ISO_PATH="$ISO_DIR/build/pulsaros-${BRANCH}-${DISTRO}-refind.iso"
        fi
    else
        if $WITH_NVIDIA; then
            ISO_PATH="$ISO_DIR/build/pulsaros-${BRANCH}-${DISTRO}-nvidia.iso"
        else
            ISO_PATH="$ISO_DIR/build/pulsaros-${BRANCH}-${DISTRO}.iso"
        fi
    fi

    if [ ! -f "$ISO_PATH" ]; then
        echo "❌ Error: No se encontró la imagen ISO en: $ISO_PATH"
        if $WITH_NVIDIA; then
            echo "Ejecuta primero: ./build-iso.sh --branch $BRANCH --$BOOTLOADER --nvidia"
        else
            echo "Ejecuta primero: ./build-iso.sh --branch $BRANCH --$BOOTLOADER"
        fi
        exit 1
    fi

    echo "🖥️  Iniciando máquina virtual QEMU ($QEMU_BIN) cargando imagen ISO..."
    echo "💿 ISO: $ISO_PATH"

    # English: Detect if OVMF UEFI BIOS is available on the host to boot the UEFI ISO
    # Español: Detectar si la BIOS OVMF UEFI está disponible en el host para arrancar la ISO UEFI
    BIOS_ARG=""
    if [ "$HOST_ARCH" = "x86_64" ]; then
        if [ -f "/usr/share/edk2/x64/OVMF.4m.fd" ]; then
            BIOS_ARG="-bios /usr/share/edk2/x64/OVMF.4m.fd"
        elif [ -f "/usr/share/ovmf/OVMF.fd" ]; then
            BIOS_ARG="-bios /usr/share/ovmf/OVMF.fd"
        elif [ -f "/usr/share/edk2-ovmf/x64/OVMF.fd" ]; then
            BIOS_ARG="-bios /usr/share/edk2-ovmf/x64/OVMF.fd"
        fi
        if [ -n "$BIOS_ARG" ]; then
            echo "🔒 UEFI: Cargando firmware OVMF UEFI ($BIOS_ARG) / UEFI: Loading OVMF UEFI firmware..."
        fi
    fi

    # Create a temporary virtual disk if it does not exist (needed for testing the Calamares installer)
    DISK_PATH="/tmp/pulsaros-test-disk.qcow2"
    if [ ! -f "$DISK_PATH" ]; then
        echo "💾 Creando disco virtual temporal de 30GB en $DISK_PATH..."
        qemu-img create -f qcow2 "$DISK_PATH" 30G
    fi

    # Detección de backend de audio
    AUDIO_ARGS="-audiodev none,id=snd0"
    if [ -S "/run/user/$HOST_UID/pulse/native" ]; then
        AUDIO_ARGS="-audiodev pa,id=snd0,server=unix:/run/user/$HOST_UID/pulse/native"
    fi

    # Lanzamiento de QEMU con la ISO como CD-ROM
    "$QEMU_BIN" \
        -m 8G \
        -smp 8 \
        $ACCEL \
        $BIOS_ARG \
        -drive file="$DISK_PATH",format=qcow2,media=disk,if=virtio \
        -cdrom "$ISO_PATH" \
        -device virtio-vga \
        -display gtk,show-cursor=on \
        $AUDIO_ARGS \
        -device intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -device qemu-xhci \
        -device usb-tablet \
        -boot d \
        -serial mon:stdio
else
    echo "🖥️  Iniciando máquina virtual QEMU ($QEMU_BIN)..."
    echo "📂 Chroot Target: $ROOTFS"
    echo "🐧 Kernel: $(basename "$KERNEL")"
    echo "📦 Initrd: $(basename "$INITRD")"

    # Autorización de pantalla para root
    if command -v xhost &>/dev/null; then
        xhost +si:localuser:root 2>/dev/null || xhost +local: 2>/dev/null || true
    fi
    HOST_XAUTH="${XAUTHORITY:-$HOME/.Xauthority}"
    HOST_UID=$(id -u)

    # Detección de backend de audio
    AUDIO_ARGS="-audiodev none,id=snd0"
    if [ -S "/run/user/$HOST_UID/pulse/native" ]; then
        AUDIO_ARGS="-audiodev pa,id=snd0,server=unix:/run/user/$HOST_UID/pulse/native"
    fi

    # Lanzamiento de QEMU con soporte de vídeo VirtIO, audio redirigido y montaje del chroot en vivo
    pkexec env \
        DISPLAY="${DISPLAY:-:0}" \
        XAUTHORITY="$HOST_XAUTH" \
        GDK_BACKEND="x11" \
        "$QEMU_BIN" \
        -m 8G \
        -smp 8 \
        $ACCEL \
        -kernel "$KERNEL" \
        -initrd "$INITRD" \
        -append "root=rootfs rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=262144 console=$CONSOLE quiet splash plymouth.ignore-serial-consoles fbcon=nodefer loglevel=3" \
        -fsdev local,id=rootfs,path="$ROOTFS",security_model=passthrough \
        -device virtio-9p-pci,fsdev=rootfs,mount_tag=rootfs \
        -device virtio-vga \
        -display gtk,show-cursor=on \
        $AUDIO_ARGS \
        -device intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -device qemu-xhci \
        -device usb-tablet \
        -serial mon:stdio
fi
