#!/usr/bin/env bash
# ==============================================================================
# Script: build-recovery-image.sh
# Purpose: Builds a dedicated, lightweight Debian + Fluxbox Recovery Environment
#          featuring the Rust-based Pulsar OS Recovery Assistant.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSAR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/configs"
BUILD_DIR="${SCRIPT_DIR}/build/recovery"
OUTPUT_DIR="${SCRIPT_DIR}/build/recovery-out"

DEBIAN_VERSION="trixie"
ARCH="amd64"
MIRROR="http://deb.debian.org/debian"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

echo "======================================================================="
echo "🛠️  BUILDING DEDICATED PULSAR OS RECOVERY ENVIRONMENT (DEBIAN + FLUXBOX)"
echo "======================================================================="

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

ROOTFS_REC="$BUILD_DIR/rootfs-recovery"
PACKAGE_LIST_FILE="$CONFIG_DIR/recovery-debian.list"

if [ ! -f "$PACKAGE_LIST_FILE" ]; then
    echo "❌ Error: $PACKAGE_LIST_FILE not found!"
    exit 1
fi

# Build / update the Rust recovery assistant binary first
echo "🦀 Compiling Pulsar OS Recovery Assistant (Rust)..."
(
    cd "$PULSAR_ROOT/PKG/pulsaros-recovery/rust-recovery"
    cargo build --release
    mkdir -p "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin"
    cp -f target/release/pulsar-recovery-assistant "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant"
)

# 1. Bootstrap Minimal Debian if not cached
if [ ! -f "$ROOTFS_REC/etc/debian_version" ]; then
    echo "📥 Bootstrapping minimal Debian ($DEBIAN_VERSION)..."
    $SUDO rm -rf "$ROOTFS_REC"
    $SUDO mkdir -p "$ROOTFS_REC"

    PACKAGES=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')

    if command -v mmdebstrap >/dev/null 2>&1; then
        echo "Using mmdebstrap..."
        $SUDO mmdebstrap \
            --architecture="$ARCH" \
            --components="main,contrib,non-free,non-free-firmware" \
            --variant=apt \
            --include="$PACKAGES" \
            "$DEBIAN_VERSION" \
            "$ROOTFS_REC" \
            "$MIRROR"
    elif command -v debootstrap >/dev/null 2>&1; then
        echo "Using debootstrap..."
        PKG_SPACE=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ' ')
        $SUDO debootstrap \
            --arch="$ARCH" \
            --components="main,contrib,non-free,non-free-firmware" \
            --include="$PKG_SPACE" \
            "$DEBIAN_VERSION" \
            "$ROOTFS_REC" \
            "$MIRROR"
    else
        echo "❌ Neither mmdebstrap nor debootstrap is installed. Please install debootstrap."
        exit 1
    fi
else
    echo "✨ Cached Debian recovery rootfs found in $ROOTFS_REC"
fi

# 2. Configure Recovery OS inside Rootfs
echo "⚙️ Configuring Recovery Environment (live user, autologin, Fluxbox, Rust assistant)..."

# Set hostname and networking
$SUDO bash -c "echo 'pulsaros-recovery' > '$ROOTFS_REC/etc/hostname'"
$SUDO bash -c "cat << 'HOSTS' > '$ROOTFS_REC/etc/hosts'
127.0.0.1   localhost
127.0.1.1   pulsaros-recovery
::1         localhost ip6-localhost ip6-loopback
HOSTS"

# Install Rust recovery assistant binary & assets into recovery rootfs
$SUDO mkdir -p "$ROOTFS_REC/usr/bin" "$ROOTFS_REC/usr/share/pulsaros-recovery" "$ROOTFS_REC/usr/share/pulsar-boot-icons"
$SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant" "$ROOTFS_REC/usr/bin/"
$SUDO cp -rf "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/share/pulsaros-recovery/." "$ROOTFS_REC/usr/share/pulsaros-recovery/" 2>/dev/null || true
$SUDO cp -rf "$PULSAR_ROOT/PKG/pulsar-boot-icons/." "$ROOTFS_REC/usr/share/pulsar-boot-icons/" 2>/dev/null || true
$SUDO chmod +x "$ROOTFS_REC/usr/bin/pulsar-recovery-assistant"

# Configure user 'live' and permissions
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    if ! id live >/dev/null 2>&1; then
        useradd -m -s /bin/bash live
        for g in sudo audio video plugdev disk users input; do
            groupadd -f \"\$g\" 2>/dev/null || true
            usermod -aG \"\$g\" live 2>/dev/null || true
        done
        echo 'live:live' | chpasswd 2>/dev/null || true
        passwd -d live 2>/dev/null || true
    fi
    mkdir -p /etc/sudoers.d
    echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-live-user
    echo 'ALL ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/99-live-user
    chmod 0440 /etc/sudoers.d/99-live-user
"

# Configure systemd autologin on tty1
$SUDO mkdir -p "$ROOTFS_REC/etc/systemd/system/getty@tty1.service.d"
$SUDO bash -c "cat << 'GETTY' > '$ROOTFS_REC/etc/systemd/system/getty@tty1.service.d/override.conf'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin live --noclear %I \$TERM
Type=idle
GETTY"

# Configure auto-start of X11 and Fluxbox with Rust recovery assistant
$SUDO mkdir -p "$ROOTFS_REC/home/live/.fluxbox" "$ROOTFS_REC/etc/skel/.fluxbox"

$SUDO bash -c "cat << 'XINIT' > '$ROOTFS_REC/home/live/.xinitrc'
#!/bin/sh
xsetroot -solid '#1e1e24'
xset s off -dpms
exec fluxbox
XINIT"

$SUDO bash -c "cat << 'FLUX_STARTUP' > '$ROOTFS_REC/home/live/.fluxbox/startup'
#!/bin/sh
# Start background color
xsetroot -solid '#18181b'

# Launch the Rust recovery assistant in fullscreen
/usr/bin/pulsar-recovery-assistant &

# Launch Fluxbox
exec /usr/bin/fluxbox
FLUX_STARTUP"

$SUDO chmod +x "$ROOTFS_REC/home/live/.xinitrc" "$ROOTFS_REC/home/live/.fluxbox/startup"
$SUDO cp -f "$ROOTFS_REC/home/live/.xinitrc" "$ROOTFS_REC/etc/skel/.xinitrc"
$SUDO cp -f "$ROOTFS_REC/home/live/.fluxbox/startup" "$ROOTFS_REC/etc/skel/.fluxbox/startup"

# Auto-start X on tty1 login
$SUDO bash -c "cat << 'PROFILE' >> '$ROOTFS_REC/home/live/.bash_profile'
if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then
    exec startx -- -nocursor 2>/dev/null || exec startx
fi
PROFILE"
$SUDO cp -f "$ROOTFS_REC/home/live/.bash_profile" "$ROOTFS_REC/etc/skel/.bash_profile"

# Unlock root and configure systemd environment
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    passwd -d root 2>/dev/null || true
    echo 'SYSTEMD_SULOGIN_FORCE=1' >> /etc/environment
    echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0' > /etc/fstab
    systemctl mask networking.service NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
"

# Configure kernel modules for live-boot overlay in initramfs
$SUDO bash -c "cat << 'MODS' > '$ROOTFS_REC/etc/initramfs-tools/modules'
overlay
squashfs
loop
ext4
btrfs
vfat
fat
isofs
MODS"

# Configure live-boot defaults
$SUDO mkdir -p "$ROOTFS_REC/etc/live"
$SUDO bash -c "cat << 'LIVECONF' > '$ROOTFS_REC/etc/live/boot.conf'
LIVE_BOOT_COMPONENTS=\"yes\"
LIVE_USERNAME=\"live\"
LIVE_USER_DEFAULT_GROUPS=\"sudo audio video plugdev disk users input\"
LIVECONF"

# Mount virtual filesystems and generate robust live-boot initramfs
$SUDO mount -t proc proc "$ROOTFS_REC/proc" 2>/dev/null || true
$SUDO mount -t sysfs sys "$ROOTFS_REC/sys" 2>/dev/null || true
$SUDO mount --bind /dev "$ROOTFS_REC/dev" 2>/dev/null || true

$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf 2>/dev/null || true
    update-initramfs -u -k all
"

$SUDO umount -l "$ROOTFS_REC/proc" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_REC/sys" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_REC/dev" 2>/dev/null || true

# 3. Extract recovery kernel and initramfs
echo "📦 Extracting recovery kernel and initramfs..."
REC_VMLINUZ=$($SUDO find "$ROOTFS_REC/boot" -maxdepth 1 -name "vmlinuz*" | head -n 1)
REC_INITRD=$($SUDO find "$ROOTFS_REC/boot" -maxdepth 1 -name "initrd.img*" | head -n 1)

if [ -z "$REC_VMLINUZ" ] || [ -z "$REC_INITRD" ]; then
    echo "❌ Error: Could not locate vmlinuz or initrd.img in $ROOTFS_REC/boot"
    exit 1
fi

$SUDO cp -f "$REC_VMLINUZ" "$OUTPUT_DIR/vmlinuz-recovery"
$SUDO cp -f "$REC_INITRD" "$OUTPUT_DIR/initramfs-recovery.img"
echo "✅ Recovery kernel: $OUTPUT_DIR/vmlinuz-recovery"
echo "✅ Recovery initrd: $OUTPUT_DIR/initramfs-recovery.img"

# 4. Generate Recovery SquashFS
echo "📦 Generating Debian Recovery SquashFS..."
SQUASHFS_REC="$OUTPUT_DIR/filesystem.squashfs"
$SUDO rm -f "$SQUASHFS_REC"
$SUDO mksquashfs "$ROOTFS_REC" "$SQUASHFS_REC" \
    -comp xz \
    -b 1048576 \
    -Xdict-size 100% \
    -wildcards \
    -e "var/cache/apt/archives/*" \
    -e "var/lib/apt/lists/*" \
    -e "tmp/*" \
    -e "var/tmp/*" \
    -noappend

echo "======================================================================="
echo "✅ PULSAR OS RECOVERY ENVIRONMENT BUILT SUCCESSFULLY!"
echo "   SquashFS:  $SQUASHFS_REC"
echo "   Kernel:    $OUTPUT_DIR/vmlinuz-recovery"
echo "   Initramfs: $OUTPUT_DIR/initramfs-recovery.img"
echo "======================================================================="
