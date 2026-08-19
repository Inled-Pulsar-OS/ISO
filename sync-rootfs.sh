#!/bin/bash
# ==============================================================================
# Pulsar OS - Fast Clean Rootfs Regenerator & Tester
# ==============================================================================
# Clones rootfs-base -> rootfs-target cleanly, installs local PKG packages,
# compiles schemas/caches, and optionally launches QEMU for instant testing.
# ==============================================================================

set -e

ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(realpath -m "$ISO_DIR/../PKG")"
BUILD_DIR="$ISO_DIR/build"

# Arguments
DISTRO="arch"
BRANCH="stable"
WITH_NVIDIA=false
LAUNCH_QEMU=false

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --nvidia)
            WITH_NVIDIA=true
            shift
            ;;
        --run|--qemu)
            LAUNCH_QEMU=true
            shift
            ;;
        *)
            echo "❌ Opción desconocida: $1"
            echo "Uso: $0 [--arch|--debian] [--branch stable|forky|rolling] [--nvidia] [--run]"
            exit 1
            ;;
    esac
done

if $WITH_NVIDIA; then
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-$DISTRO-nvidia"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-$DISTRO-nvidia"
else
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-$DISTRO"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-$DISTRO"
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    echo "❌ Error: No existe el rootfs base en: $ROOTFS_BASE"
    echo "Ejecuta primero build-iso.sh para generar la base virgen."
    exit 1
fi

echo "=============================================================================="
echo "⚡ Regenerando rootfs-target limpio para $DISTRO ($BRANCH)..."
echo "📂 Base:   $ROOTFS_BASE"
echo "🎯 Target: $ROOTFS_TARGET"
echo "=============================================================================="

cleanup() {
    pkexec /bin/bash -c "
        umount -l '$ROOTFS_TARGET/proc' 2>/dev/null || true
        umount -l '$ROOTFS_TARGET/sys' 2>/dev/null || true
        umount -l '$ROOTFS_TARGET/dev/pts' 2>/dev/null || true
        umount -l '$ROOTFS_TARGET/dev' 2>/dev/null || true
        rm -rf '$ROOTFS_TARGET/tmp/packages' 2>/dev/null || true
    " 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Unmount and recreate target from clean base
cleanup
echo "🔄 Clonando rootfs-base limpio a rootfs-target..."
pkexec /bin/bash -c "
    rm -rf '$ROOTFS_TARGET'
    mkdir -p '$ROOTFS_TARGET'
    rsync -aHAXx --delete '$ROOTFS_BASE/' '$ROOTFS_TARGET/'
"

# 2. Configure mounts, pacman repositories & DNS
echo "⚙️ Configurando repositorios, montajes del sistema y DNS..."
pkexec /bin/bash -c "
    mount -t proc proc '$ROOTFS_TARGET/proc'
    mount -t sysfs sys '$ROOTFS_TARGET/sys'
    mount --bind /dev '$ROOTFS_TARGET/dev'
    mount --bind /dev/pts '$ROOTFS_TARGET/dev/pts'
    echo 'nameserver 8.8.8.8' > '$ROOTFS_TARGET/etc/resolv.conf'

    if [ '$DISTRO' = 'arch' ]; then
        mkdir -p '$ROOTFS_TARGET/usr/share/keyrings'
        if [ -f '$ISO_DIR/configs/inled-archive-keyring.gpg' ]; then
            cp '$ISO_DIR/configs/inled-archive-keyring.gpg' '$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg'
        fi

        sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' '$ROOTFS_TARGET/etc/pacman.conf'
        sed -i '0,/^[[:space:]]*SigLevel/s/^[[:space:]]*SigLevel.*/SigLevel = Optional TrustAll/' '$ROOTFS_TARGET/etc/pacman.conf'

        if ! grep -q '\[inled\]' '$ROOTFS_TARGET/etc/pacman.conf'; then
            tee -a '$ROOTFS_TARGET/etc/pacman.conf' > /dev/null <<'PEOF'

[inled]
SigLevel = Never
Server = https://apt.inled.es/arch/
PEOF
        else
            sed -i '/\[inled\]/{n;s/.*/SigLevel = Never/}' '$ROOTFS_TARGET/etc/pacman.conf'
        fi
    fi
"

# 3. Install packages
if [ "$DISTRO" = "arch" ]; then
    echo "📦 Instalando paquetes locales de Pulsar OS (Arch)..."
    PACKAGES_DIR="$PKG_DIR/arch/build/packages"
    if [ -d "$PACKAGES_DIR" ]; then
        pkexec /bin/bash -c "
            mkdir -p '$ROOTFS_TARGET/tmp/packages'
            cp '$PACKAGES_DIR'/*.pkg.tar.zst '$ROOTFS_TARGET/tmp/packages/' 2>/dev/null || true
            rm -f '$ROOTFS_TARGET/tmp/packages'/autokey-qt-*.pkg.tar.zst 2>/dev/null || true
            rm -f '$ROOTFS_TARGET/tmp/packages'/*-debug-*.pkg.tar.zst 2>/dev/null || true

            chroot '$ROOTFS_TARGET' /bin/bash -c '
                pacman-key --init 2>/dev/null || true
                pacman-key --populate archlinux 2>/dev/null || true
                if [ -f /usr/share/keyrings/inled-archive-keyring.gpg ]; then
                    pacman-key --add /usr/share/keyrings/inled-archive-keyring.gpg 2>/dev/null || true
                    pacman-key --lsign-key 89F828A9675B63CD0077CE9965AA57CF36E2018F 2>/dev/null || true
                fi
                pacman -Syy --noconfirm
                pacman -U --noconfirm --overwrite \"*\" /tmp/packages/*.pkg.tar.zst
                
                # Ensure 9p and virtio modules are included in initramfs for QEMU direct chroot booting
                sed -i \"s/HOOKS=.*/HOOKS=(base udev microcode modconf kms keyboard keymap consolefont plymouth block filesystems fsck)/\" /etc/mkinitcpio.conf
                sed -i \"s/MODULES=.*/MODULES=(i915 amdgpu radeon nouveau 9p 9pnet 9pnet_virtio virtio_pci virtio_blk virtio_balloon)/\" /etc/mkinitcpio.conf
                mkinitcpio -P 2>/dev/null

                glib-compile-schemas /usr/share/glib-2.0/schemas/
                gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
                update-desktop-database /usr/share/applications 2>/dev/null || true

                # Fix GSConnect config.js paths if present
                GSCONFIG=\"/usr/share/gnome-shell/extensions/gsconnect@andyholmes.github.io/config.js\"
                if [ -f \"\$GSCONFIG\" ]; then
                    sed -i \"s|'/usr/local/share/|'/usr/share/|g\" \"\$GSCONFIG\"
                fi
                find /etc/skel/.config/gtk-4.0/ -name \"*.css\" -exec sed -i \"/@define-color accent_/d\" {} + 2>/dev/null || true
                find /root/.config/gtk-4.0/ -name \"*.css\" -exec sed -i \"/@define-color accent_/d\" {} + 2>/dev/null || true
            '
            chmod -R a+r '$ROOTFS_TARGET/boot' 2>/dev/null || true
        "
    else
        echo "⚠️ Advertencia: No se encontró el directorio de paquetes en $PACKAGES_DIR"
    fi
else
    echo "📦 Instalando paquetes locales de Pulsar OS (Debian)..."
    DEBS_DIR="$PKG_DIR/debian/build/packages"
    if [ -d "$DEBS_DIR" ]; then
        pkexec /bin/bash -c "
            mkdir -p '$ROOTFS_TARGET/tmp/packages'
            cp '$DEBS_DIR'/*.deb '$ROOTFS_TARGET/tmp/packages/' 2>/dev/null || true
            chroot '$ROOTFS_TARGET' /bin/bash -c '
                dpkg -i --force-overwrite /tmp/packages/*.deb 2>/dev/null || apt-get install -f -y --allow-downgrades
                glib-compile-schemas /usr/share/glib-2.0/schemas/
                gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

                # Fix GSConnect config.js paths if present
                GSCONFIG=\"/usr/share/gnome-shell/extensions/gsconnect@andyholmes.github.io/config.js\"
                if [ -f \"\$GSCONFIG\" ]; then
                    sed -i \"s|'/usr/local/share/|'/usr/share/|g\" \"\$GSCONFIG\"
                fi
            '
            chmod -R a+r '$ROOTFS_TARGET/boot' 2>/dev/null || true
        "
    fi
fi

cleanup
echo "✅ Rootfs limpio regenerado y actualizado con éxito en: $ROOTFS_TARGET"

# 4. Optional QEMU launch
if $LAUNCH_QEMU; then
    echo "🚀 Iniciando QEMU..."
    "$ISO_DIR/run-qemu.sh" "--$DISTRO" --branch "$BRANCH" $( $WITH_NVIDIA && echo "--nvidia" )
fi
