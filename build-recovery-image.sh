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
BRANCH="${BRANCH:-stable}"
USE_LOCAL_PKGS="${USE_LOCAL_PKGS:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --local-pkgs)
            USE_LOCAL_PKGS=true
            shift
            ;;
        --prod)
            USE_LOCAL_PKGS=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

echo "======================================================================="
echo "🛠️  BUILDING DEDICATED PULSAR OS RECOVERY ENVIRONMENT (DEBIAN + FLUXBOX)"
echo "======================================================================="

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

## Helper: Unmount directory tree safely
unmount_tree() {
    local target_dir="$1"
    [ -z "$target_dir" ] && return 0
    [ ! -d "$target_dir" ] && return 0
    awk '$2 ~ "^'"$target_dir"'/" || $2 == "'"$target_dir"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
    for mp in "$target_dir/dev/pts" "$target_dir/dev/shm" "$target_dir/dev" "$target_dir/proc" "$target_dir/sys" "$target_dir/run"; do
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
}

cleanup_rec() {
    unmount_tree "$ROOTFS_REC"
    unmount_tree "$BASE_DIR"
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

# Optional: compile local Rust recovery assistant binary if in local development mode
if [ -d "$PULSAR_ROOT/PKG/pulsaros-recovery/rust-recovery" ]; then
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" 2>/dev/null || true
    if command -v cargo >/dev/null 2>&1; then
        echo "🦀 Compiling Pulsar OS Recovery Assistant (Rust) from local source..."
        (
            cd "$PULSAR_ROOT/PKG/pulsaros-recovery/rust-recovery"
            cargo build --release
            mkdir -p "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin"
            cp -f target/release/pulsar-recovery-assistant "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant"
        ) || echo "⚠️ Local Rust recovery compilation failed, using existing binary."
    fi
fi

# ==============================================================================
# PHASE 1: Bootstrap clean Debian base (cached, only when missing or packages changed)
# ==============================================================================

base_list_changed=false
if [ -d "$BASE_DIR" ] && [ -f "$PACKAGE_LIST_FILE" ]; then
    current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | sort -u)
    if [ ! -f "$BASE_DIR/etc/pulsaros-recovery-base.list" ]; then
        echo "🔄 Base package list not found in cache. Rebuilding base..."
        base_list_changed=true
    else
        cached_list=$(grep -v '^#' "$BASE_DIR/etc/pulsaros-recovery-base.list" 2>/dev/null | grep -v '^$' | sort -u || true)
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

    if ! command -v mmdebstrap >/dev/null 2>&1 && ! command -v debootstrap >/dev/null 2>&1; then
        if command -v pacman >/dev/null 2>&1; then
            echo "📥 Installing debootstrap and debian-archive-keyring on Arch host..."
            $SUDO pacman -Sy --noconfirm --needed debootstrap debian-archive-keyring 2>/dev/null || true
        elif command -v apt-get >/dev/null 2>&1; then
            echo "📥 Installing mmdebstrap and debian-archive-keyring on Debian/Ubuntu host..."
            $SUDO apt-get update -y 2>/dev/null || true
            $SUDO apt-get install -y mmdebstrap debian-archive-keyring 2>/dev/null || true
        fi
    fi

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
    grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | sort -u | $SUDO tee "$BASE_DIR/etc/pulsaros-recovery-base.list" > /dev/null

    echo "✅ Clean Debian base bootstrapped at $BASE_DIR"
else
    echo "✨ Cached clean Debian base found at $BASE_DIR"
    # Ensure any newly added packages in recovery-debian.list are installed in the cached base
    PKG_SPACE=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ' ')
    $SUDO mount -t proc proc "$BASE_DIR/proc" 2>/dev/null || true
    $SUDO mount -t sysfs sys "$BASE_DIR/sys" 2>/dev/null || true
    $SUDO mount --bind /dev "$BASE_DIR/dev" 2>/dev/null || true
    $SUDO mount --bind /dev/pts "$BASE_DIR/dev/pts" 2>/dev/null || true

    $SUDO chroot "$BASE_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends $PKG_SPACE
        apt-get clean
    " 2>/dev/null || true

    $SUDO umount -l "$BASE_DIR/dev/pts" 2>/dev/null || true
    $SUDO umount -l "$BASE_DIR/dev" 2>/dev/null || true
    $SUDO umount -l "$BASE_DIR/sys" 2>/dev/null || true
    $SUDO umount -l "$BASE_DIR/proc" 2>/dev/null || true
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

# Mount virtual filesystems and configure DNS for package installation
$SUDO mount -t proc proc "$ROOTFS_REC/proc" 2>/dev/null || true
$SUDO mount -t sysfs sys "$ROOTFS_REC/sys" 2>/dev/null || true
$SUDO mount --bind /dev "$ROOTFS_REC/dev" 2>/dev/null || true
$SUDO mount --bind /dev/pts "$ROOTFS_REC/dev/pts" 2>/dev/null || true

$SUDO rm -f "$ROOTFS_REC/etc/resolv.conf"
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n" | $SUDO tee "$ROOTFS_REC/etc/resolv.conf" > /dev/null

# Set hostname and networking
$SUDO bash -c "echo 'pulsaros-recovery' > '$ROOTFS_REC/etc/hostname'"
$SUDO bash -c "cat << 'HOSTS' > '$ROOTFS_REC/etc/hosts'
127.0.0.1   localhost
127.0.1.1   pulsaros-recovery
::1         localhost ip6-localhost ip6-loopback
HOSTS"

# Set up Inled APT repository
echo "🔑 Configuring Inled repository (apt.inled.es)..."
$SUDO mkdir -p "$ROOTFS_REC/usr/share/keyrings" "$ROOTFS_REC/etc/apt/sources.list.d" "$ROOTFS_REC/etc/apt/preferences.d"
if [ -f "$CONFIG_DIR/inled-archive-keyring.gpg" ]; then
    $SUDO cp "$CONFIG_DIR/inled-archive-keyring.gpg" "$ROOTFS_REC/usr/share/keyrings/inled-archive-keyring.gpg"
elif [ -f "/usr/share/keyrings/inled-archive-keyring.gpg" ]; then
    $SUDO cp "/usr/share/keyrings/inled-archive-keyring.gpg" "$ROOTFS_REC/usr/share/keyrings/inled-archive-keyring.gpg"
fi

$SUDO bash -c "cat << 'INLEDLIST' > '$ROOTFS_REC/etc/apt/sources.list.d/inled.list'
deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es ${BRANCH:-stable} main
INLEDLIST"

$SUDO bash -c "cat << 'INLEDPIN' > '$ROOTFS_REC/etc/apt/preferences.d/99inled'
Package: *
Pin: origin \"apt.inled.es\"
Pin-Priority: 1001
INLEDPIN"

# Install Pulsar OS packages from apt.inled.es
echo "📦 Installing Pulsar OS packages (pulsaros-recovery, pulsaros-boot-icons, pulsaros-plymouth, pulsaros-theme)..."
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    echo 'DPkg::options { \"--force-overwrite\"; };' > /etc/apt/apt.conf.d/99force-overwrite
    apt-get update
    apt-get install -y --no-install-recommends \
        pulsaros-recovery \
        pulsaros-boot-icons \
        pulsaros-plymouth \
        pulsaros-theme || true
    rm -f /etc/apt/apt.conf.d/99force-overwrite
    apt-get clean
"

# Optional local overrides for development mode
if [ "$USE_LOCAL_PKGS" = "true" ] || [ -f "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant" ]; then
    if [ -f "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant" ]; then
        echo "📂 Overriding with local Rust recovery assistant binary..."
        $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant" "$ROOTFS_REC/usr/bin/"
    fi
    if [ -d "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/share/pulsaros-recovery" ]; then
        $SUDO cp -rf "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/share/pulsaros-recovery/." "$ROOTFS_REC/usr/share/pulsaros-recovery/" 2>/dev/null || true
    fi
    if [ -d "$PULSAR_ROOT/PKG/pulsar-boot-icons" ]; then
        $SUDO cp -rf "$PULSAR_ROOT/PKG/pulsar-boot-icons/." "$ROOTFS_REC/usr/share/pulsar-boot-icons/" 2>/dev/null || true
    fi
fi

if [ -f "$ROOTFS_REC/usr/bin/pulsar-recovery-assistant" ]; then
    $SUDO chmod +x "$ROOTFS_REC/usr/bin/pulsar-recovery-assistant"
fi

# Configure user 'live' and permissions
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    if ! id live >/dev/null 2>&1; then
        useradd -m -s /bin/bash live
        for g in sudo audio video render tty plugdev disk users input; do
            groupadd -f \"\$g\" 2>/dev/null || true
            usermod -aG \"\$g\" live 2>/dev/null || true
        done
        echo 'live:live' | chpasswd 2>/dev/null || true
        passwd -u live 2>/dev/null || true
    fi
    for g in sudo audio video render tty plugdev disk users input; do
        groupadd -f \"\$g\" 2>/dev/null || true
        usermod -aG \"\$g\" live 2>/dev/null || true
    done
    mkdir -p /etc/sudoers.d
    echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-live-user
    echo 'ALL ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/99-live-user
    chmod 0440 /etc/sudoers.d/99-live-user
"

# Configure dedicated systemd graphical service for recovery (bypasses agetty/PAM login loop completely)
$SUDO bash -c "cat << 'GUISVC' > '$ROOTFS_REC/etc/systemd/system/pulsar-recovery-gui.service'
[Unit]
Description=Pulsar OS Recovery GUI Assistant
After=systemd-user-sessions.service plymouth-quit-wait.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=live
PAMName=login
Environment=HOME=/home/live
Environment=USER=live
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=GTK_THEME=MacTahoe-Dark
Environment=XCURSOR_THEME=MacTahoe-dark
Environment=XCURSOR_SIZE=24
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
ExecStart=/usr/bin/xinit /home/live/.xinitrc -- /usr/bin/X :0 vt1 -keeptty -nolisten tcp
Restart=always
RestartSec=1

[Install]
WantedBy=graphical.target
GUISVC"

$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    systemctl enable pulsar-recovery-gui.service 2>/dev/null || true
    systemctl mask getty@tty1.service 2>/dev/null || true
"

# Configure X11 permissions for non-root / tty startup
$SUDO mkdir -p "$ROOTFS_REC/etc/X11"
$SUDO bash -c "cat << 'XWRAP' > '$ROOTFS_REC/etc/X11/Xwrapper.config'
allowed_users=anybody
needs_root_rights=yes
XWRAP"
$SUDO chmod 4755 "$ROOTFS_REC/usr/lib/xorg/Xorg.wrap" 2>/dev/null || true

# Configure auto-start of X11 and Fluxbox with Rust recovery assistant
$SUDO mkdir -p "$ROOTFS_REC/home/live/.fluxbox" "$ROOTFS_REC/etc/skel/.fluxbox"

$SUDO bash -c "cat << 'XINIT' > '$ROOTFS_REC/home/live/.xinitrc'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
xsetroot -solid '#18181b'
xset s off -dpms
[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources
xhost +local: 2>/dev/null || xhost + 2>/dev/null || true
export GTK_THEME=\"MacTahoe-Dark\"
export XCURSOR_THEME=\"MacTahoe-dark\"
export XCURSOR_SIZE=\"24\"
/usr/bin/pulsar-recovery-assistant &
exec /usr/bin/fluxbox
XINIT"

$SUDO bash -c "cat << 'FLUX_STARTUP' > '$ROOTFS_REC/home/live/.fluxbox/startup'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
xsetroot -solid '#18181b'
[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources
xhost +local: 2>/dev/null || xhost + 2>/dev/null || true
export GTK_THEME=\"MacTahoe-Dark\"
export XCURSOR_THEME=\"MacTahoe-dark\"
export XCURSOR_SIZE=\"24\"
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

# Auto-start X on tty1 login without looping on failure
$SUDO bash -c "cat << 'PROFILE' >> '$ROOTFS_REC/home/live/.bash_profile'
if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then
    startx -- -nocursor 2>/tmp/xorg.log || startx >>/tmp/xorg.log 2>&1 || {
        echo \"⚠️ Error al iniciar servidor gráfico X11. Registro en /tmp/xorg.log\"
        echo \"💡 Puedes intentar ejecutar manualmente: sudo /usr/bin/pulsar-recovery-assistant\"
    }
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
echo "🎨 Configuring Pulsar OS Plymouth theme into recovery environment..."
$SUDO mkdir -p "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth"
if [ ! -f "$ROOTFS_REC/usr/share/plymouth/themes/pulsar-plymouth/pulsar-plymouth.plymouth" ]; then
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
echo "🎨 Configuring MacTahoe theme, icons, and cursor theme into recovery environment..."
$SUDO mkdir -p "$ROOTFS_REC/usr/share/themes" "$ROOTFS_REC/usr/share/icons"

# 1. MacTahoe GTK Theme
if [ ! -d "$ROOTFS_REC/usr/share/themes/MacTahoe-Dark" ]; then
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
fi

# 2. MacTahoe Icons and Cursors
if [ ! -d "$ROOTFS_REC/usr/share/icons/MacTahoe-blue-dark" ]; then
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
fi

# 3. Configure GTK-3.0, GTK-4.0, Xcursor and environment
$SUDO mkdir -p "$ROOTFS_REC/etc/gtk-3.0" "$ROOTFS_REC/home/live/.config/gtk-3.0" "$ROOTFS_REC/home/live/.config/gtk-4.0" "$ROOTFS_REC/root/.config/gtk-3.0" "$ROOTFS_REC/root/.config/gtk-4.0" "$ROOTFS_REC/etc/skel/.config/gtk-3.0" "$ROOTFS_REC/etc/skel/.config/gtk-4.0"

$SUDO bash -c "cat << 'GTK3CONF' > '$ROOTFS_REC/etc/gtk-3.0/settings.ini'
[Settings]
gtk-theme-name = MacTahoe-Dark
gtk-icon-theme-name = MacTahoe-blue-dark
gtk-cursor-theme-name = MacTahoe-dark
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
Xcursor.theme: MacTahoe-dark
Xcursor.size: 24
XRES"
$SUDO cp -f "$ROOTFS_REC/home/live/.Xresources" "$ROOTFS_REC/etc/skel/.Xresources"
$SUDO cp -f "$ROOTFS_REC/home/live/.Xresources" "$ROOTFS_REC/root/.Xresources"

# Configure environment variables
$SUDO bash -c "cat << 'ENVVARS' >> '$ROOTFS_REC/etc/environment'
GTK_THEME=MacTahoe-Dark
XCURSOR_THEME=MacTahoe-dark
XCURSOR_SIZE=24
ENVVARS"

# Ensure proper ownership
$SUDO chown -R 1000:1000 "$ROOTFS_REC/home/live" 2>/dev/null || true

# Unlock root and configure systemd environment
$SUDO chroot "$ROOTFS_REC" /bin/bash -c "
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    echo 'root:root' | chpasswd
    echo 'live:live' | chpasswd
    echo 'SYSTEMD_SULOGIN_FORCE=1' >> /etc/environment
    echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0' > /etc/fstab
    systemctl mask networking.service NetworkManager-wait-online.service systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask systemd-fsck-root.service systemd-fsck@.service systemd-remount-fs.service e2scrub_reap.service 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
"

# Force-unlock root and live in /etc/shadow by removing lock prefix (! or !!)
# passwd -u can fail silently; sed is deterministic and cannot fail here.
$SUDO sed -i 's/^root:!!:/root::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true
$SUDO sed -i 's/^root:!:/root::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true
$SUDO sed -i 's/^live:!!:/live::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true
$SUDO sed -i 's/^live:!:/live::/' "$ROOTFS_REC/etc/shadow" 2>/dev/null || true

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
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf 2>/dev/null || true
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        plymouth-set-default-theme pulsar-plymouth 2>/dev/null || plymouth-set-default-theme spinner 2>/dev/null || true
    fi
    update-initramfs -u -k all
"

# Thoroughly unmount all virtual filesystems in $ROOTFS_REC
echo "🧹 Unmounting all virtual filesystems in recovery rootfs..."
unmount_tree "$ROOTFS_REC"

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
# Clean temporary files, logs, and potential nologin locks
$SUDO rm -f "$ROOTFS_REC/etc/nologin" "$ROOTFS_REC/run/nologin" "$ROOTFS_REC/var/run/nologin" 2>/dev/null || true
$SUDO rm -rf "$ROOTFS_REC"/tmp/* "$ROOTFS_REC"/var/tmp/* 2>/dev/null || true

# Generate Recovery SquashFS
echo "📦 Generating Debian Recovery SquashFS..."
SQUASHFS_REC="$OUTPUT_DIR/filesystem.squashfs"
$SUDO rm -f "$SQUASHFS_REC"
$SUDO mksquashfs "$ROOTFS_REC" "$SQUASHFS_REC" \
    -comp xz \
    -b 1048576 \
    -Xdict-size 100% \
    -processors $(nproc) \
    -noappend \
    -e proc/* \
    -e sys/* \
    -e dev/* \
    -e run/* \
    -e tmp/* \
    -e var/tmp/* \
    -e var/log/* \
    -e var/cache/apt/archives/* \
    -e var/lib/apt/lists/*

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
unmount_tree "$ROOTFS_REC"
$SUDO rm -rf "$ROOTFS_REC"

echo "======================================================================="
echo "✅ PULSAR OS RECOVERY ENVIRONMENT BUILT SUCCESSFULLY!"
echo "   SquashFS:  $SQUASHFS_REC"
echo "   Kernel:    $OUTPUT_DIR/vmlinuz-recovery"
echo "   Initramfs: $OUTPUT_DIR/initramfs-recovery.img"
echo "======================================================================="
