#!/usr/bin/env bash
# ==============================================================================
# Script: build-recovery-image.sh
# Purpose: Builds a dedicated, lightweight Debian + Fluxbox Recovery Environment
#          featuring the Rust-based Pulsar OS Recovery Assistant.
#
#          Uses a cached clean Debian base (base-recovery) and clones it fresh
#          every build, so configuration changes always take effect.
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

cleanup_rec() {
    for mp in "$ROOTFS_REC/proc" "$ROOTFS_REC/sys" "$ROOTFS_REC/dev/pts" "$ROOTFS_REC/dev" "$BASE_DIR/dev/pts" "$BASE_DIR/dev" "$BASE_DIR/sys" "$BASE_DIR/proc"; do
        if [ -d "$mp" ] && mountpoint -q "$mp" 2>/dev/null; then
            $SUDO umount -l "$mp" 2>/dev/null || true
        fi
    done
    if [ -e /dev/kvm ]; then
        $SUDO chmod 666 /dev/kvm 2>/dev/null || true
        $SUDO chown root:kvm /dev/kvm 2>/dev/null || true
    fi
}
trap cleanup_rec EXIT INT TERM

# base-recovery: cached clean Debian rootfs (only rebuilt when missing or package list changes)
# rootfs-recovery: fresh clone from base, configured every build, then discarded
BASE_DIR="$BUILD_DIR/base-recovery"
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

# ==============================================================================
# PHASE 1: Bootstrap clean Debian base (cached, only when missing or packages changed)
# ==============================================================================

base_list_changed=false
if [ -d "$BASE_DIR" ] && [ -f "$PACKAGE_LIST_FILE" ]; then
    current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | sort)
    if [ ! -f "$BASE_DIR/etc/pulsaros-recovery-base.list" ]; then
        echo "🔄 Base package list not found in cache. Rebuilding base..."
        base_list_changed=true
    else
        cached_list=$(cat "$BASE_DIR/etc/pulsaros-recovery-base.list")
        if [ "$current_list" != "$cached_list" ]; then
            echo "🔄 Package list changed since last base build. Rebuilding base..."
            base_list_changed=true
        fi
    fi
fi

if $base_list_changed; then
    echo "🧹 Cleaning stale base cache..."
    $SUDO rm -rf "$BASE_DIR"
fi

if [ ! -f "$BASE_DIR/etc/debian_version" ]; then
    echo "📥 Bootstrapping clean minimal Debian base ($DEBIAN_VERSION)..."
    $SUDO rm -rf "$BASE_DIR"
    $SUDO mkdir -p "$BASE_DIR"

    PACKAGES=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')

    if command -v mmdebstrap >/dev/null 2>&1; then
        echo "Using mmdebstrap..."
        $SUDO mmdebstrap \
            --architecture="$ARCH" \
            --components="main,contrib,non-free,non-free-firmware" \
            --variant=apt \
            --include="$PACKAGES" \
            "$DEBIAN_VERSION" \
            "$BASE_DIR" \
            "$MIRROR"
    elif command -v debootstrap >/dev/null 2>&1; then
        echo "Using debootstrap (minbase + apt install)..."
        $SUDO debootstrap \
            --arch="$ARCH" \
            --components="main,contrib,non-free,non-free-firmware" \
            --variant=minbase \
            "$DEBIAN_VERSION" \
            "$BASE_DIR" \
            "$MIRROR"
        
        # Configure sources.list
        $SUDO bash -c "cat << 'SOURCES' > '$BASE_DIR/etc/apt/sources.list'
deb $MIRROR $DEBIAN_VERSION main contrib non-free non-free-firmware
deb $MIRROR $DEBIAN_VERSION-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_VERSION-security main contrib non-free non-free-firmware
SOURCES"

        # Mount virtual filesystems and install packages cleanly
        $SUDO mount -t proc proc "$BASE_DIR/proc" 2>/dev/null || true
        $SUDO mount -t sysfs sys "$BASE_DIR/sys" 2>/dev/null || true
        $SUDO mount --bind /dev "$BASE_DIR/dev" 2>/dev/null || true
        $SUDO mount --bind /dev/pts "$BASE_DIR/dev/pts" 2>/dev/null || true

        PKG_SPACE=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ' ')
        $SUDO chroot "$BASE_DIR" /bin/bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends $PKG_SPACE
            apt-get clean
        "

        $SUDO umount -l "$BASE_DIR/dev/pts" 2>/dev/null || true
        $SUDO umount -l "$BASE_DIR/dev" 2>/dev/null || true
        $SUDO umount -l "$BASE_DIR/sys" 2>/dev/null || true
        $SUDO umount -l "$BASE_DIR/proc" 2>/dev/null || true
    else
        echo "❌ Neither mmdebstrap nor debootstrap is installed. Please install debootstrap."
        exit 1
    fi

    # Save the package list into the base for future change detection
    grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | $SUDO tee "$BASE_DIR/etc/pulsaros-recovery-base.list" > /dev/null

    echo "✅ Clean Debian base bootstrapped at $BASE_DIR"
else
    echo "✨ Cached clean Debian base found at $BASE_DIR"
fi

# ==============================================================================
# PHASE 2: Clone clean base → working rootfs (always fresh)
# ==============================================================================

echo "🔄 Cloning clean base into working rootfs..."

# Unmount any leftover mounts from a previous interrupted build
for mp in "$ROOTFS_REC/proc" "$ROOTFS_REC/sys" "$ROOTFS_REC/dev/pts" "$ROOTFS_REC/dev"; do
    if mountpoint -q "$mp" 2>/dev/null; then
        $SUDO umount -l "$mp" 2>/dev/null || true
    fi
done

$SUDO rm -rf "$ROOTFS_REC"
$SUDO rsync -aHAXx --delete "$BASE_DIR/" "$ROOTFS_REC/"

echo "✅ Fresh clone ready at $ROOTFS_REC"

# ==============================================================================
# PHASE 3: Configure Recovery OS inside the fresh clone
# ==============================================================================

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
ExecStart=-/sbin/agetty --autologin live --noclear %I 38400 linux
Type=idle
GETTY"

# Configure X11 non-root permissions
$SUDO mkdir -p "$ROOTFS_REC/etc/X11"
$SUDO bash -c "cat << 'XWRAP' > '$ROOTFS_REC/etc/X11/Xwrapper.config'
allowed_users=anybody
needs_root_rights=no
XWRAP"

# Configure auto-start of X11 and Fluxbox with Rust recovery assistant
$SUDO mkdir -p "$ROOTFS_REC/home/live/.fluxbox" "$ROOTFS_REC/etc/skel/.fluxbox"

$SUDO bash -c "cat << 'XINIT' > '$ROOTFS_REC/home/live/.xinitrc'
#!/bin/sh
xsetroot -solid '#18181b'
xset s off -dpms
[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources
xhost +local: 2>/dev/null || xhost + 2>/dev/null || true
export GTK_THEME=\"MacTahoe-Dark\"
export XCURSOR_THEME=\"MacTahoe-blue-dark\"
export XCURSOR_SIZE=\"24\"
/usr/bin/pulsar-recovery-assistant &
exec /usr/bin/fluxbox
XINIT"

$SUDO bash -c "cat << 'FLUX_STARTUP' > '$ROOTFS_REC/home/live/.fluxbox/startup'
#!/bin/sh
xsetroot -solid '#18181b'
[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources
xhost +local: 2>/dev/null || xhost + 2>/dev/null || true
export GTK_THEME=\"MacTahoe-Dark\"
export XCURSOR_THEME=\"MacTahoe-blue-dark\"
export XCURSOR_SIZE=\"24\"
/usr/bin/pulsar-recovery-assistant &
exec /usr/bin/fluxbox
FLUX_STARTUP"

$SUDO chmod +x "$ROOTFS_REC/home/live/.xinitrc" "$ROOTFS_REC/home/live/.fluxbox/startup"
$SUDO cp -f "$ROOTFS_REC/home/live/.xinitrc" "$ROOTFS_REC/etc/skel/.xinitrc"
$SUDO cp -f "$ROOTFS_REC/home/live/.fluxbox/startup" "$ROOTFS_REC/etc/skel/.fluxbox/startup"

# Configure passwordless sudo and X11 display preservation for live user
$SUDO mkdir -p "$ROOTFS_REC/etc/sudoers.d"
$SUDO bash -c "cat << 'SUDOERS' > '$ROOTFS_REC/etc/sudoers.d/live'
live ALL=(ALL:ALL) NOPASSWD: ALL
Defaults:live !requiretty
Defaults:live env_keep += \"DISPLAY XAUTHORITY WAYLAND_DISPLAY\"
SUDOERS"
$SUDO chmod 0440 "$ROOTFS_REC/etc/sudoers.d/live"

# Auto-start X on tty1 login
$SUDO bash -c "cat << 'PROFILE' >> '$ROOTFS_REC/home/live/.bash_profile'
if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then
    exec startx -- -nocursor 2>/dev/null || exec startx
fi
PROFILE"
$SUDO cp -f "$ROOTFS_REC/home/live/.bash_profile" "$ROOTFS_REC/etc/skel/.bash_profile"

# Ensure proper ownership of live user home directory
$SUDO chown -R 1000:1000 "$ROOTFS_REC/home/live" 2>/dev/null || true

# Configure live-boot shutdown to poweroff/reboot cleanly without media removal prompt
$SUDO mkdir -p "$ROOTFS_REC/etc/live" "$ROOTFS_REC/etc/default"
$SUDO bash -c "cat << 'LIVECONF' > '$ROOTFS_REC/etc/live/boot.conf'
LIVE_NOPROMPT=yes
LIVECONF"
$SUDO bash -c "cat << 'LIVETOOLS' > '$ROOTFS_REC/etc/default/live-tools'
OPTIONS=\"--noprompt\"
LIVETOOLS"
$SUDO rm -f "$ROOTFS_REC/lib/systemd/system-shutdown/live-tools.shutdown" 2>/dev/null || true
$SUDO rm -f "$ROOTFS_REC/usr/lib/systemd/system-shutdown/live-tools.shutdown" 2>/dev/null || true

# Install Pulsar OS Plymouth theme
echo "🎨 Installing Pulsar OS Plymouth theme into recovery environment..."
$SUDO mkdir -p "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth"
if [ -d "$BUILD_DIR/rootfs-target-stable-arch/usr/share/plymouth/themes/pulsar-plymouth" ]; then
    $SUDO cp -r "$BUILD_DIR/rootfs-target-stable-arch/usr/share/plymouth/themes/pulsar-plymouth"/* "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/"
elif [ -d "$PULSAR_ROOT/PKG/pulsaros-plymouth/repo" ]; then
    $SUDO cp -r "$PULSAR_ROOT/PKG/pulsaros-plymouth/repo"/* "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/"
else
    TEMP_PLY="/tmp/pulsaros-recovery-plymouth"
    rm -rf "$TEMP_PLY"
    git clone --depth=1 "https://github.com/Inled-Pulsar-OS/plymouth-macoslike" "$TEMP_PLY" 2>/dev/null || true
    if [ -d "$TEMP_PLY" ]; then
        $SUDO cp -r "$TEMP_PLY"/* "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/"
        rm -rf "$TEMP_PLY"
    fi
fi

if [ -d "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/images" ]; then
    $SUDO mv "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/images"/* "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/" 2>/dev/null || true
    $SUDO rm -rf "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/images"
fi

$SUDO mkdir -p "$ROOTFS_REC/etc/plymouth"
$SUDO bash -c "cat << 'PLYCONF' > '$ROOTFS_REC/etc/plymouth/plymouthd.conf'
[Daemon]
Theme=pulsar-plymouth
ShowDelay=0
DeviceTimeout=8
UseFirmwareBackground=false
UseSimpledrm=false
PLYCONF"

# ----------------------------------------------------------------------
# Install MacTahoe GTK Theme, Icons & Cursors into Recovery Rootfs
# ----------------------------------------------------------------------
echo "🎨 Installing MacTahoe theme, icons, and cursor theme into recovery environment..."
$SUDO mkdir -p "$ROOTFS_REC/usr/share/themes" "$ROOTFS_REC/usr/share/icons"

# 1. MacTahoe GTK Theme
if [ -d "$BUILD_DIR/rootfs-target-stable-arch/usr/share/themes/MacTahoe-Dark" ]; then
    $SUDO cp -r "$BUILD_DIR/rootfs-target-stable-arch/usr/share/themes/MacTahoe-Dark"* "$ROOTFS_REC/usr/share/themes/"
elif [ -d "$PULSAR_ROOT/PKG/build/pkg-staging/pulsaros-theme/usr/share/themes/MacTahoe-Dark" ]; then
    $SUDO cp -r "$PULSAR_ROOT/PKG/build/pkg-staging/pulsaros-theme/usr/share/themes/MacTahoe-Dark"* "$ROOTFS_REC/usr/share/themes/"
elif [ -d "/usr/share/themes/MacTahoe-Dark" ]; then
    $SUDO cp -r "/usr/share/themes/MacTahoe-Dark"* "$ROOTFS_REC/usr/share/themes/"
else
    TEMP_THEME="/tmp/pulsaros-recovery-mactahoe"
    rm -rf "$TEMP_THEME"
    git clone --depth=1 "https://github.com/Inled-Pulsar-OS/MacTahoe-gtk-theme" "$TEMP_THEME" 2>/dev/null || true
    if [ -d "$TEMP_THEME" ]; then
        $SUDO cp -r "$TEMP_THEME/src/MacTahoe-Dark"* "$ROOTFS_REC/usr/share/themes/" 2>/dev/null || true
        rm -rf "$TEMP_THEME"
    fi
fi

# 2. MacTahoe Icons and Cursors
if [ -d "$BUILD_DIR/rootfs-target-stable-arch/usr/share/icons/MacTahoe-blue-dark" ]; then
    $SUDO cp -r "$BUILD_DIR/rootfs-target-stable-arch/usr/share/icons/MacTahoe"* "$ROOTFS_REC/usr/share/icons/"
elif [ -d "$PULSAR_ROOT/PKG/build/pkg-staging/pulsaros-theme/usr/share/icons/MacTahoe-blue-dark" ]; then
    $SUDO cp -r "$PULSAR_ROOT/PKG/build/pkg-staging/pulsaros-theme/usr/share/icons/MacTahoe"* "$ROOTFS_REC/usr/share/icons/"
elif [ -d "/usr/share/icons/MacTahoe-blue-dark" ]; then
    $SUDO cp -r "/usr/share/icons/MacTahoe"* "$ROOTFS_REC/usr/share/icons/"
else
    TEMP_ICON="/tmp/pulsaros-recovery-mactahoe-icons"
    rm -rf "$TEMP_ICON"
    git clone --depth=1 "https://github.com/Inled-Pulsar-OS/MacTahoe-icon-theme" "$TEMP_ICON" 2>/dev/null || true
    if [ -d "$TEMP_ICON" ]; then
        $SUDO cp -r "$TEMP_ICON/dist/MacTahoe"* "$ROOTFS_REC/usr/share/icons/" 2>/dev/null || true
        rm -rf "$TEMP_ICON"
    fi
fi

# 3. Configure GTK-3.0, GTK-4.0, Xcursor and environment
$SUDO mkdir -p "$ROOTFS_REC/etc/gtk-3.0" "$ROOTFS_REC/home/live/.config/gtk-3.0" "$ROOTFS_REC/home/live/.config/gtk-4.0" "$ROOTFS_REC/root/.config/gtk-3.0" "$ROOTFS_REC/root/.config/gtk-4.0" "$ROOTFS_REC/etc/skel/.config/gtk-3.0" "$ROOTFS_REC/etc/skel/.config/gtk-4.0"

$SUDO bash -c "cat << 'GTK3CONF' > '$ROOTFS_REC/etc/gtk-3.0/settings.ini'
[Settings]
gtk-theme-name = MacTahoe-Dark
gtk-icon-theme-name = MacTahoe-blue-dark
gtk-cursor-theme-name = MacTahoe-blue-dark
gtk-cursor-theme-size = 24
gtk-application-prefer-dark-theme = 1
gtk-font-name = Inter 10
GTK3CONF"

$SUDO cp -f "$ROOTFS_REC/etc/gtk-3.0/settings.ini" "$ROOTFS_REC/home/live/.config/gtk-3.0/settings.ini"
$SUDO cp -f "$ROOTFS_REC/etc/gtk-3.0/settings.ini" "$ROOTFS_REC/root/.config/gtk-3.0/settings.ini"
$SUDO cp -f "$ROOTFS_REC/etc/gtk-3.0/settings.ini" "$ROOTFS_REC/etc/skel/.config/gtk-3.0/settings.ini"

if [ -d "$ROOTFS_REC/usr/share/themes/MacTahoe-Dark/gtk-4.0" ]; then
    $SUDO cp -rf "$ROOTFS_REC/usr/share/themes/MacTahoe-Dark/gtk-4.0/"* "$ROOTFS_REC/home/live/.config/gtk-4.0/" 2>/dev/null || true
    $SUDO cp -rf "$ROOTFS_REC/usr/share/themes/MacTahoe-Dark/gtk-4.0/"* "$ROOTFS_REC/root/.config/gtk-4.0/" 2>/dev/null || true
    $SUDO cp -rf "$ROOTFS_REC/usr/share/themes/MacTahoe-Dark/gtk-4.0/"* "$ROOTFS_REC/etc/skel/.config/gtk-4.0/" 2>/dev/null || true
fi

# Set Xresources for MacTahoe cursors
$SUDO bash -c "cat << 'XRES' > '$ROOTFS_REC/home/live/.Xresources'
Xcursor.theme: MacTahoe-blue-dark
Xcursor.size: 24
XRES"
$SUDO cp -f "$ROOTFS_REC/home/live/.Xresources" "$ROOTFS_REC/etc/skel/.Xresources"
$SUDO cp -f "$ROOTFS_REC/home/live/.Xresources" "$ROOTFS_REC/root/.Xresources"

# Configure environment variables
$SUDO bash -c "cat << 'ENVVARS' >> '$ROOTFS_REC/etc/environment'
GTK_THEME=MacTahoe-Dark
XCURSOR_THEME=MacTahoe-blue-dark
XCURSOR_SIZE=24
ENVVARS"

# Ensure proper ownership
$SUDO chown -R 1000:1000 "$ROOTFS_REC/home/live" 2>/dev/null || true

# Unlock root and configure systemd environment
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    echo 'root:root' | chpasswd
    echo 'live:live' | chpasswd
    echo 'SYSTEMD_SULOGIN_FORCE=1' >> /etc/environment
    echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0' > /etc/fstab
    systemctl mask networking.service NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask systemd-fsck-root.service systemd-fsck@.service systemd-remount-fs.service e2scrub_reap.service 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
"

# Force-unlock root in /etc/shadow by removing lock prefix (! or !!)
# passwd -u can fail silently; sed is deterministic and cannot fail here.
$SUDO sed -i 's/^root:!!:/root::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true
$SUDO sed -i 's/^root:!:/root::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true

# Remove OnFailure=emergency.target from local-fs.target to prevent fallback on overlayfs
$SUDO mkdir -p "$ROOTFS_REC/etc/systemd/system/local-fs.target.d"
$SUDO bash -c "cat << 'LOCALFS' > '$ROOTFS_REC/etc/systemd/system/local-fs.target.d/override.conf'
[Unit]
OnFailure=
LOCALFS"

# Configure emergency and rescue services to provide direct root shell without password prompt
# Write overrides to BOTH /etc/systemd/ and /run/systemd/ so they are found regardless
# of whether systemd in the initramfs uses the overlay or tmpfs as its config root.
for _d in "$ROOTFS_REC/etc/systemd/system" "$ROOTFS_REC/run/systemd/system"; do
    $SUDO mkdir -p "$_d/emergency.service.d" "$_d/rescue.service.d"
    $SUDO bash -c "cat << 'EMERG' > '$_d/emergency.service.d/override.conf'
[Service]
Environment=SYSTEMD_SULOGIN_FORCE=1
ExecStart=
ExecStart=-/bin/sh -c 'exec /bin/bash'
EMERG"
    $SUDO bash -c "cat << 'RESC' > '$_d/rescue.service.d/override.conf'
[Service]
Environment=SYSTEMD_SULOGIN_FORCE=1
ExecStart=
ExecStart=-/bin/sh -c 'exec /bin/bash'
RESC"
done

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

# ==============================================================================
# PHASE 4: Generate initramfs, kernel, and SquashFS
# ==============================================================================

# Mount virtual filesystems and generate robust live-boot initramfs
$SUDO mount -t proc proc "$ROOTFS_REC/proc" 2>/dev/null || true
$SUDO mount -t sysfs sys "$ROOTFS_REC/sys" 2>/dev/null || true
$SUDO mount --bind /dev "$ROOTFS_REC/dev" 2>/dev/null || true

$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf 2>/dev/null || true
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        plymouth-set-default-theme pulsar-plymouth 2>/dev/null || plymouth-set-default-theme spinner 2>/dev/null || true
    fi
    update-initramfs -u -k all
"

$SUDO umount -l "$ROOTFS_REC/proc" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_REC/sys" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_REC/dev" 2>/dev/null || true

# Extract recovery kernel and initramfs
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

# Generate Recovery SquashFS
echo "📦 Generating Debian Recovery SquashFS..."
SQUASHFS_REC="$OUTPUT_DIR/filesystem.squashfs"
$SUDO rm -f "$SQUASHFS_REC"
$SUDO mksquashfs "$ROOTFS_REC" "$SQUASHFS_REC" \
    -comp xz \
    -b 1048576 \
    -Xdict-size 100% \
    -processors $(nproc) \
    -wildcards \
    -e "var/cache/apt/archives/*" \
    -e "var/lib/apt/lists/*" \
    -e "tmp/*" \
    -e "var/tmp/*" \
    -noappend

# Verify SquashFS was generated correctly
if [ ! -f "$SQUASHFS_REC" ] || [ ! -s "$SQUASHFS_REC" ]; then
    echo "❌ Error: Recovery SquashFS is missing or empty: $SQUASHFS_REC"
    exit 1
fi
SQUASHFS_SIZE=$(du -h "$SQUASHFS_REC" | cut -f1)
echo "✅ Recovery SquashFS verified: $SQUASHFS_REC ($SQUASHFS_SIZE)"
echo ""
echo "📋 Boot params expected by live-boot:"
echo "   boot=live live-media=any live-media-path=live"
echo "   → SquashFS must be at: <partition>/live/filesystem.squashfs"
echo ""

# Clean up working rootfs (the base is kept cached)
echo "🧹 Cleaning working rootfs..."
for mp in "$ROOTFS_REC/proc" "$ROOTFS_REC/sys" "$ROOTFS_REC/dev/pts" "$ROOTFS_REC/dev"; do
    $SUDO umount -l "$mp" 2>/dev/null || true
done
$SUDO rm -rf "$ROOTFS_REC"

echo "======================================================================="
echo "✅ PULSAR OS RECOVERY ENVIRONMENT BUILT SUCCESSFULLY!"
echo "   SquashFS:  $SQUASHFS_REC"
echo "   Kernel:    $OUTPUT_DIR/vmlinuz-recovery"
echo "   Initramfs: $OUTPUT_DIR/initramfs-recovery.img"
echo "======================================================================="
