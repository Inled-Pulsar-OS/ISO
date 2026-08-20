#!/bin/bash
# ==============================================================================
# Tube OS - ISO Builder
# ==============================================================================
# Builds Tube OS ISO images (Debian and Arch editions).
# Works like build-iso.sh but for Tube OS, without modifying existing files.
#
# Usage:
#   ./tubeos/build-tubeos.sh [--arch] [--debian] [--grub] [--refind] [--local] [--clean-base]
#
# Options:
#   --arch        Build Arch edition (includes Plasma Bigscreen)
#   --debian      Build Debian edition (headless, dashboard only) [default]
#   --grub        Use GRUB bootloader [default]
#   --refind      Use rEFInd bootloader
#   --local       Compile all local packages before building ISO
#   --clean-base  Force re-download of base system
# ==============================================================================

set -e

# ==============================================================================
# Parse arguments
# ==============================================================================
DISTRO="debian"
BOOTLOADER="grub"
USE_LOCAL=false
CLEAN_BASE=false
BRANCH="stable"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)       DISTRO="arch"; shift ;;
        --debian)     DISTRO="debian"; shift ;;
        --grub)       BOOTLOADER="grub"; shift ;;
        --refind)     BOOTLOADER="refind"; shift ;;
        --local)      USE_LOCAL=true; shift ;;
        --clean-base) CLEAN_BASE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ==============================================================================
# Paths
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$(cd "$ISO_DIR/../PKG" && pwd)"
BUILD_DIR="$ISO_DIR/build"
ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-tubeos-$DISTRO"
ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-tubeos-$DISTRO"
ISO_OUTPUT="$BUILD_DIR/tubeos-$BRANCH-$DISTRO-$BOOTLOADER.iso"
PACKAGE_LIST="$ISO_DIR/configs/base-tubeos-$DISTRO.list"

if command -v pkexec >/dev/null 2>&1; then
    SUDO="pkexec"
else
    SUDO="sudo"
fi
CHROOT_BIN="$(command -v chroot || echo /usr/sbin/chroot)"

# Original user for makepkg (cannot run as root)
ORIGINAL_USER="${SUDO_USER:-$USER}"
[ "$ORIGINAL_USER" = "root" ] && ORIGINAL_USER="$(logname 2>/dev/null || echo root)"

run_as_user() {
    if [ "$ORIGINAL_USER" != "root" ]; then
        if command -v runuser >/dev/null 2>&1; then
            $SUDO runuser -u "$ORIGINAL_USER" -- "$@"
        else
            sudo -u "$ORIGINAL_USER" "$@"
        fi
    else
        "$@"
    fi
}

echo "============================================="
echo "  Tube OS ISO Builder"
echo "  Edition: $DISTRO | Bootloader: $BOOTLOADER"
echo "  Local packages: $USE_LOCAL"
echo "============================================="

# ==============================================================================
# Preflight cleanup
# ==============================================================================
cleanup() {
    echo "Cleaning chroot mounts..."
    for mp in dev/pts dev/shm dev sys proc boot/efi mnt; do
        $SUDO umount -lf "$ROOTFS_TARGET/$mp" 2>/dev/null || true
        $SUDO umount -lf "$ROOTFS_BASE/$mp" 2>/dev/null || true
    done
    awk '$2 ~ "^'"$BUILD_DIR"'/" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM
cleanup

if [ -d "$ROOTFS_TARGET" ]; then
    $SUDO rm -rf "$ROOTFS_TARGET"
fi

# Clean base if requested or if corrupt/incomplete
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/usr" ]; }; then
    echo "  Incomplete or corrupt base cache detected. Cleaning..."
    $SUDO rm -rf "$ROOTFS_BASE"
fi

if $CLEAN_BASE && [ -d "$ROOTFS_BASE" ]; then
    echo "Cleaning base cache..."
    $SUDO rm -rf "$ROOTFS_BASE"
fi

mkdir -p "$BUILD_DIR"

# ==============================================================================
# STEP 1: Build local packages (--local mode)
# ==============================================================================
if $USE_LOCAL; then
    echo ""
    echo ">>> STEP 1: Building local packages..."

    if [ "$DISTRO" = "arch" ]; then
        # --- Arch: build with makepkg ---
        PKGBUILDS_DIR="$PKG_DIR/arch/pkgbuilds"
        LOCAL_PKGS_DIR="$BUILD_DIR/local-packages-tubeos"
        mkdir -p "$LOCAL_PKGS_DIR"

        # Build order: branding first (no deps), then others
        TUBEOS_PKGS="tubeos-branding tubeos-plymouth dockermigrate tube-os-dash tubeos-installer"

        for pkg in $TUBEOS_PKGS; do
            PKGBUILD_DIR="$PKGBUILDS_DIR/$pkg"
            if [ ! -d "$PKGBUILD_DIR" ]; then
                echo "  SKIP: $pkg (no PKGBUILD found at $PKGBUILD_DIR)"
                continue
            fi
            echo "  Building $pkg..."
            run_as_user bash -c "cd '$PKGBUILD_DIR' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -cfd --noconfirm --nosign 2>&1" || {
                echo "  WARN: $pkg build failed, continuing..."
            }
        done

        # Also check if tube-os-dash PKGBUILD exists in the main PKG dir
        if [ -d "$PKG_DIR/arch/pkgbuilds/tube-os-dash" ]; then
            echo "  Building tube-os-dash..."
            run_as_user bash -c "cd '$PKG_DIR/arch/pkgbuilds/tube-os-dash' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -cfd --noconfirm --nosign 2>&1" || true
        fi

        # Deduplicate: keep newest version of each package
        echo "  Deduplicating packages..."
        cd "$LOCAL_PKGS_DIR"
        for base in $(ls *.pkg.tar.zst 2>/dev/null | sed 's/-[0-9].*//' | sort -u); do
            newest=$(ls -t ${base}-*.pkg.tar.zst 2>/dev/null | head -1)
            for f in ${base}-*.pkg.tar.zst; do
                [ "$f" != "$newest" ] && rm -f "$f" "$f.sig" 2>/dev/null
            done
        done

        PKG_COUNT=$(ls "$LOCAL_PKGS_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)
        echo "  Built $PKG_COUNT local packages in $LOCAL_PKGS_DIR"

    else
        # --- Debian: build with dpkg-deb ---
        LOCAL_DEBS_DIR="$BUILD_DIR/local-debs-tubeos"
        mkdir -p "$LOCAL_DEBS_DIR"

        TUBEOS_PKGS="tubeos-branding tubeos-plymouth dockermigrate tube-os-dash tubeos-installer"

        for pkg in $TUBEOS_PKGS; do
            PKG_SRC="$PKG_DIR/$pkg"
            if [ ! -d "$PKG_SRC/DEBIAN" ]; then
                echo "  SKIP: $pkg (no DEBIAN/control at $PKG_SRC)"
                continue
            fi
            echo "  Building $pkg..."

            PKG_VER=$(grep "^Version:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')
            PKG_NAME=$(grep "^Package:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')
            ARCH=$(grep "^Architecture:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')

            DEB_FILE="${LOCAL_DEBS_DIR}/${PKG_NAME}_${PKG_VER}_${ARCH}.deb"

            dpkg-deb --build --root-owner-group "$PKG_SRC" "$DEB_FILE" >/dev/null 2>&1 || \
            dpkg-deb --build "$PKG_SRC" "$DEB_FILE" >/dev/null 2>&1 || {
                echo "  WARN: $pkg build failed"
            }
        done

        DEB_COUNT=$(ls "$LOCAL_DEBS_DIR"/*.deb 2>/dev/null | wc -l)
        echo "  Built $DEB_COUNT local packages in $LOCAL_DEBS_DIR"
    fi
fi

# ==============================================================================
# STEP 2: Bootstrap base system
# ==============================================================================
echo ""
echo ">>> STEP 2: Bootstrapping $DISTRO base..."

if [ "$DISTRO" = "arch" ]; then
    if [ ! -d "$ROOTFS_BASE" ]; then
        echo "  Downloading Arch Linux base..."
        CLEAN_PACMAN_CONF="/tmp/tubeos-pacman-$$.conf"
        cp /etc/pacman.conf "$CLEAN_PACMAN_CONF"
        # Ensure [inled] repo is configured
        if ! grep -q '\[inled\]' "$CLEAN_PACMAN_CONF"; then
            cat >> "$CLEAN_PACMAN_CONF" << 'REPOEOF'

[inled]
SigLevel = Optional TrustAll
Server = https://apt.inled.es/arch/
REPOEOF
        fi
        # Get base packages from list
        BASE_PKGS=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -vE 'tubeos-|tube-os-|dockermigrate|plasma-|kodi|python-' | tr '\n' ' ')
        $SUDO pacstrap -c -C "$CLEAN_PACMAN_CONF" -K "$ROOTFS_BASE" $BASE_PKGS
        rm -f "$CLEAN_PACMAN_CONF"
    fi
    $SUDO cp -a "$ROOTFS_BASE" "$ROOTFS_TARGET"
else
    if [ ! -d "$ROOTFS_BASE" ]; then
        if [ -d "$BUILD_DIR/rootfs-base-stable-debian" ] && [ -d "$BUILD_DIR/rootfs-base-stable-debian/etc" ]; then
            echo "  Reusing local virgin Debian base cache..."
            $SUDO cp -a "$BUILD_DIR/rootfs-base-stable-debian" "$ROOTFS_BASE"
        else
            echo "  Downloading Debian base (trixie)..."
            BASE_PKGS=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -vE 'tubeos-|tube-os-|dockermigrate' | paste -sd, -)
            $SUDO debootstrap --include="$BASE_PKGS" trixie "$ROOTFS_BASE" http://deb.debian.org/debian
        fi
    fi
    $SUDO cp -a "$ROOTFS_BASE" "$ROOTFS_TARGET"
fi

# ==============================================================================
# STEP 3: Mount chroot
# ==============================================================================
echo ""
echo ">>> STEP 3: Setting up chroot..."
$SUDO mount -t proc proc "$ROOTFS_TARGET/proc"
$SUDO mount -t sysfs sys "$ROOTFS_TARGET/sys"
$SUDO mount --bind /dev "$ROOTFS_TARGET/dev"
$SUDO mount --bind /dev/pts "$ROOTFS_TARGET/dev/pts"

# DNS
echo "nameserver 8.8.8.8" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

# Plymouth theme dir (satisfy hooks)
$SUDO mkdir -p "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos"
$SUDO ln -sf . "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos/images" 2>/dev/null || true

# ==============================================================================
# STEP 4: Install Tube OS packages
# ==============================================================================
echo ""
echo ">>> STEP 4: Installing Tube OS packages..."

if [ "$DISTRO" = "arch" ]; then
    # Configure repos
    $SUDO tee "$ROOTFS_TARGET/etc/pacman.conf" > /dev/null << 'PACCONF'
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Optional TrustAll
LocalFileSigLevel = Optional
NoProgressBar
ParallelDownloads = 5

[inled]
SigLevel = Optional TrustAll
Server = https://apt.inled.es/arch/

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PACCONF
    $SUDO sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' "$ROOTFS_TARGET/etc/pacman.conf"

    # Keyring
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/" 2>/dev/null || true

    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && pacman -Sy --noconfirm" || true

    if $USE_LOCAL; then
        echo "  Installing local packages..."
        LOCAL_PKGS_DIR="$BUILD_DIR/local-packages-tubeos"
        if [ -d "$LOCAL_PKGS_DIR" ] && ls "$LOCAL_PKGS_DIR"/*.pkg.tar.zst &>/dev/null; then
            $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
            $SUDO cp "$LOCAL_PKGS_DIR"/*.pkg.tar.zst "$ROOTFS_TARGET/tmp/packages/"

            # Get tubeos-specific packages from list
            TUBEOS_PKG_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate' | tr '\n' ' ')

            $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                pacman -U --noconfirm /tmp/packages/*.pkg.tar.zst 2>/dev/null || true
                pacman -S --noconfirm $TUBEOS_PKG_NAMES 2>/dev/null || true
            "
            $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        fi
    else
        echo "  Installing from repos..."
        TUBEOS_PKG_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate|python-' | tr '\n' ' ')
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            pacman -Sy --noconfirm
            pacman -S --noconfirm $TUBEOS_PKG_NAMES
        "
    fi

    # Bootloader
    if [ "$BOOTLOADER" = "grub" ]; then
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && pacman -S --noconfirm grub efibootmgr"
    else
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && pacman -S --noconfirm refind efibootmgr grub"
    fi

else
    # --- Debian ---
    $SUDO tee "$ROOTFS_TARGET/etc/apt/sources.list" > /dev/null << 'SRLIST'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
SRLIST

    if $USE_LOCAL; then
        echo "  Installing local packages..."
        LOCAL_DEBS_DIR="$BUILD_DIR/local-debs-tubeos"
        if [ -d "$LOCAL_DEBS_DIR" ] && ls "$LOCAL_DEBS_DIR"/*.deb &>/dev/null; then
            $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
            $SUDO cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"

            # Get tubeos-specific packages
            TUBEOS_DEB_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate' | tr '\n' ' ')

            $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                dpkg -i /tmp/packages/*.deb 2>/dev/null || true
                apt-get install -f -y -qq 2>/dev/null || true
                apt-get install -y -qq $TUBEOS_DEB_NAMES 2>/dev/null || true
                apt-get clean
            "
            $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        fi
    else
        echo "  Installing from repos..."
        TUBEOS_DEB_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate|python3-' | tr '\n' ' ')

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq $TUBEOS_DEB_NAMES
            apt-get clean
        "
    fi

    # Bootloader
    if [ "$BOOTLOADER" = "grub" ]; then
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq grub-pc grub-efi-amd64-bin efibootmgr
        "
    else
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq refind efibootmgr grub-pc grub-efi-amd64-bin
        "
    fi
fi

# ==============================================================================
# STEP 5: Apply overlay (systemd services, motd, etc.)
# ==============================================================================
echo ""
echo ">>> STEP 5: Applying overlay..."
$SUDO cp -r "$SCRIPT_DIR/overlay/"* "$ROOTFS_TARGET/" 2>/dev/null || true

# Copy installer files directly (fallback if package install failed)
if [ ! -f "$ROOTFS_TARGET/usr/share/tubeos-installer/server.py" ]; then
    echo "  Copying installer files directly..."
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/tubeos-installer/static"
    $SUDO cp -r "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/"* "$ROOTFS_TARGET/usr/share/tubeos-installer/"
    $SUDO cp "$PKG_DIR/tubeos-installer/usr/bin/tubeos-installer" "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
fi

# Copy branding
if [ ! -f "$ROOTFS_TARGET/usr/share/tubeos/logo.png" ]; then
    echo "  Copying branding files directly..."
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/tubeos"
    $SUDO cp "$PKG_DIR/tubeos-branding/usr/share/tubeos/logo.png" "$ROOTFS_TARGET/usr/share/tubeos/" 2>/dev/null || true
    $SUDO cp "$PKG_DIR/tubeos-branding/usr/share/tubeos/logo.svg" "$ROOTFS_TARGET/usr/share/tubeos/" 2>/dev/null || true
fi

# Copy installer static assets
$SUDO mkdir -p "$ROOTFS_TARGET/usr/share/tubeos-installer/static"
$SUDO cp "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/static/"* "$ROOTFS_TARGET/usr/share/tubeos-installer/static/" 2>/dev/null || true

# ==============================================================================
# STEP 6: Configure live system
# ==============================================================================
echo ""
echo ">>> STEP 6: Configuring live system..."

# Auto-login as root on tty1
$SUDO mkdir -p "$ROOTFS_TARGET/etc/systemd/system/getty@tty1.service.d"
$SUDO tee "$ROOTFS_TARGET/etc/systemd/system/getty@tty1.service.d/autologin.conf" > /dev/null << 'AUTOCONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOCONF

# Unlock root account without password for live session
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    passwd -d root 2>/dev/null || true
" || true

# Clear static MOTD (dynamic banner is handled via /etc/profile.d/tubeos-banner.sh)
$SUDO truncate -s 0 "$ROOTFS_TARGET/etc/motd"

# Copy / write interactive Tube OS banner
$SUDO tee "$ROOTFS_TARGET/usr/bin/tubeos-banner" > /dev/null << 'BANNEREOF'
#!/bin/bash
# ==============================================================================
# Tube OS Interactive Banner & IP / QR Detector
# ==============================================================================
set +e

# Wait for IP address
IP=""
for i in {1..8}; do
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    if [ -z "$IP" ]; then
        IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [ -n "$IP" ] && [ "$IP" != "127.0.0.1" ] && break
    sleep 0.5
done

IP="${IP:-127.0.0.1}"
URL="http://${IP}"

echo ""
echo -e "\033[1;36m  =======================================================\033[0m"
echo -e "\033[1;37m                 Welcome to Tube OS \033[0m"
echo -e "\033[1;36m  =======================================================\033[0m"
echo ""
echo -e "  \033[1;32mWeb Access URL:\033[0m \033[1;37mhttp://tubeos.local\033[0m (or \033[1;37m${URL}\033[0m)"
echo -e "  \033[1;33mDockerMigrate:\033[0m  \033[1;37mhttp://tubeos.local:8070\033[0m (or \033[1;37mhttp://${IP}:8070\033[0m)"
echo ""
echo -e "  \033[1;35mScan this QR code with your mobile camera:\033[0m"
echo ""

# Render QR code
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${URL}"
elif python3 -c "import qrcode" >/dev/null 2>&1; then
    python3 -c "
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data('${URL}')
qr.make(fit=True)
qr.print_ascii(invert=True)
" 2>/dev/null || true
elif command -v tubeos-cli >/dev/null 2>&1; then
    tubeos-cli qrcode 2>/dev/null || true
fi

echo ""
echo -e "  \033[90mManagement Commands:\033[0m"
echo -e "    \033[37mtubeos-cli --help\033[0m       - Tube OS CLI tools"
echo -e "    \033[37mjournalctl -u tubeos-installer -f\033[0m - Installer logs"
echo ""
BANNEREOF
$SUDO chmod 0755 "$ROOTFS_TARGET/usr/bin/tubeos-banner"

# Configure profile.d to show banner on interactive login
$SUDO tee "$ROOTFS_TARGET/etc/profile.d/tubeos-banner.sh" > /dev/null << 'PROFILEEOF'
#!/bin/bash
if [ -t 0 ] && [ "$SHLVL" -le 2 ]; then
    /usr/bin/tubeos-banner
fi
PROFILEEOF
$SUDO chmod 0755 "$ROOTFS_TARGET/etc/profile.d/tubeos-banner.sh"

# Set hostname and hosts for tubeos.local
echo "tubeos" | $SUDO tee "$ROOTFS_TARGET/etc/hostname" > /dev/null
$SUDO sed -i '/tubeos/d' "$ROOTFS_TARGET/etc/hosts" 2>/dev/null || true
echo "127.0.0.1 localhost tubeos tubeos.local" | $SUDO tee -a "$ROOTFS_TARGET/etc/hosts" > /dev/null

# Ensure installer systemd services exist
$SUDO mkdir -p "$ROOTFS_TARGET/usr/lib/systemd/system"
$SUDO cp "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/tubeos-installer.service" "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true
$SUDO cp "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/tubeos-ootb.service" "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true

# Disable graphical target, enable multi-user, networking, avahi (mDNS), and installer
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    systemctl set-default multi-user.target 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl enable tubeos-installer 2>/dev/null || true
" || true

# Install Plymouth theme
if [ -f "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos/tubeos.plymouth" ]; then
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        plymouth-set-default-theme tubeos 2>/dev/null || true
    " || true
fi

# ==============================================================================
# STEP 7: Install bootloader
# ==============================================================================
echo ""
echo ">>> STEP 7: Installing bootloader..."

if [ "$DISTRO" = "arch" ]; then
    if [ "$BOOTLOADER" = "grub" ]; then
        if [ -d /sys/firmware/efi ]; then
            $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=TubeOS
                grub-mkconfig -o /boot/grub/grub.cfg
            " || true
        else
            $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                grub-install --target=i386-pc /dev/sda
                grub-mkconfig -o /boot/grub/grub.cfg
            " || true
        fi
    else
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            refind-install 2>/dev/null || true
        " || true
    fi
else
    # Debian
    if [ "$BOOTLOADER" = "grub" ]; then
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            echo 'grub-pc grub-pc/install_devices string' | debconf-set-selections
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=TubeOS 2>/dev/null || true
            update-grub 2>/dev/null || true
        " || true
    fi
fi

# ==============================================================================
# STEP 8: Cleanup chroot mounts
# ==============================================================================
echo ""
echo ">>> STEP 8: Unmounting chroot..."
cleanup

# ==============================================================================
# STEP 9: Build ISO
# ==============================================================================
echo ""
echo ">>> STEP 9: Building ISO..."

# Create staging area
STAGING="$BUILD_DIR/tubeos-iso-staging"
$SUDO rm -rf "$STAGING"
$SUDO mkdir -p "$STAGING/live"
$SUDO mkdir -p "$STAGING/boot/grub"
$SUDO mkdir -p "$STAGING/EFI/BOOT"
$SUDO mkdir -p "$STAGING/isolinux"

# Copy kernel and initramfs from target
if [ "$DISTRO" = "arch" ]; then
    $SUDO cp "$ROOTFS_TARGET/boot/vmlinuz-linux" "$STAGING/live/vmlinuz" 2>/dev/null || \
    $SUDO cp "$ROOTFS_TARGET/boot/vmlinuz"* "$STAGING/live/vmlinuz" 2>/dev/null || true
    $SUDO cp "$ROOTFS_TARGET/boot/initramfs-linux.img" "$STAGING/live/initrd.img" 2>/dev/null || \
    $SUDO cp "$ROOTFS_TARGET/boot/initramfs"*.img "$STAGING/live/initrd.img" 2>/dev/null || true
    KERNEL_PARAMS="archisobasedir=live archisolabel=TUBE_OS copytoram=y quiet splash"
    SAFE_PARAMS="archisobasedir=live archisolabel=TUBE_OS copytoram=y nomodeset"
else
    $SUDO cp "$ROOTFS_TARGET/boot/vmlinuz-"* "$STAGING/live/vmlinuz" 2>/dev/null || true
    $SUDO cp "$ROOTFS_TARGET/boot/initrd.img-"* "$STAGING/live/initrd.img" 2>/dev/null || \
    $SUDO cp "$ROOTFS_TARGET/boot/initrd.img" "$STAGING/live/initrd.img" 2>/dev/null || true
    KERNEL_PARAMS="boot=live components quiet splash"
    SAFE_PARAMS="boot=live components nomodeset"
fi

# Create squashfs
echo "  Creating squashfs..."
SQUASHFS="$STAGING/live/filesystem.squashfs"
$SUDO mksquashfs "$ROOTFS_TARGET" "$SQUASHFS" -comp xz -b 1M -Xdict-size 100% -noappend -e boot

# GRUB config
$SUDO tee "$STAGING/boot/grub/grub.cfg" > /dev/null << GRUBCFG
set default=0
set timeout=5
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

menuentry "Tube OS Live" {
    linux /live/vmlinuz $KERNEL_PARAMS
    initrd /live/initrd.img
}

menuentry "Tube OS Live (safe mode - nomodeset)" {
    linux /live/vmlinuz $SAFE_PARAMS
    initrd /live/initrd.img
}

menuentry "Boot from first hard disk" {
    set root=(hd0)
    chainloader +1
}
GRUBCFG

# Also provide grub.cfg in EFI/BOOT/
$SUDO cp "$STAGING/boot/grub/grub.cfg" "$STAGING/EFI/BOOT/grub.cfg"

# Copy GRUB EFI and BIOS modules to staging /boot/grub/
$SUDO mkdir -p "$STAGING/boot/grub/x86_64-efi"
if [ -d "/usr/lib/grub/x86_64-efi" ]; then
    $SUDO cp -r /usr/lib/grub/x86_64-efi/* "$STAGING/boot/grub/x86_64-efi/" 2>/dev/null || true
elif [ -d "$ROOTFS_TARGET/usr/lib/grub/x86_64-efi" ]; then
    $SUDO cp -r "$ROOTFS_TARGET/usr/lib/grub/x86_64-efi/"* "$STAGING/boot/grub/x86_64-efi/" 2>/dev/null || true
fi

$SUDO mkdir -p "$STAGING/boot/grub/i386-pc"
if [ -d "/usr/lib/grub/i386-pc" ]; then
    $SUDO cp -r /usr/lib/grub/i386-pc/* "$STAGING/boot/grub/i386-pc/" 2>/dev/null || true
elif [ -d "$ROOTFS_TARGET/usr/lib/grub/i386-pc" ]; then
    $SUDO cp -r "$ROOTFS_TARGET/usr/lib/grub/i386-pc/"* "$STAGING/boot/grub/i386-pc/" 2>/dev/null || true
fi

# Create standalone GRUB EFI binary
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "  Generating standalone UEFI bootloader..."
    EARLY_CFG="/tmp/tubeos-early-grub-$$.cfg"
    cat << 'EARLYEOF' > "$EARLY_CFG"
set root=(memdisk)
set prefix=(memdisk)/boot/grub
search --no-floppy --file /live/filesystem.squashfs --set=root
set prefix=($root)/boot/grub
configfile ($root)/boot/grub/grub.cfg
EARLYEOF
    $SUDO grub-mkstandalone -d /usr/lib/grub/x86_64-efi -O x86_64-efi \
        --modules="part_gpt part_msdos fat iso9660 ntfs ext2 search search_fs_file search_fs_uuid configfile echo linux normal font all_video gfxterm test cat help gzio bufio gettext reboot" \
        -o "$STAGING/EFI/BOOT/bootx64.efi" "boot/grub/grub.cfg=$EARLY_CFG" 2>/dev/null || true
    rm -f "$EARLY_CFG"
fi

# Create BIOS El Torito boot image
echo "  Generating BIOS El Torito bootloader..."
$SUDO grub-mkimage -d /usr/lib/grub/i386-pc -O i386-pc-eltorito \
    -o "$STAGING/boot/grub/eltorito.img" \
    -p /boot/grub \
    biosdisk iso9660 search search_fs_file configfile normal 2>/dev/null || true

# Find Hybrid MBR template
HYBRID_MBR=""
for mbr in \
    "/usr/lib/grub/i386-pc/boot_hybrid.img" \
    "/usr/lib/ISOLINUX/isohdpfx.bin" \
    "/usr/lib/syslinux/mbr/isohdpfx.bin"; do
    if [ -f "$mbr" ]; then
        HYBRID_MBR="$mbr"
        break
    fi
done

# Create FAT EFI image for El Torito
EFI_IMG="$STAGING/boot/grub/efi.img"
$SUDO rm -f "$EFI_IMG"
$SUDO truncate -s 16M "$EFI_IMG"
$SUDO mkfs.vfat -F 12 -n "TUBE_EFI" "$EFI_IMG" >/dev/null 2>&1 || true
if command -v mcopy >/dev/null 2>&1 && [ -f "$STAGING/EFI/BOOT/bootx64.efi" ]; then
    $SUDO mmd -i "$EFI_IMG" ::EFI ::EFI/BOOT 2>/dev/null || true
    $SUDO mcopy -i "$EFI_IMG" "$STAGING/EFI/BOOT/bootx64.efi" ::EFI/BOOT/bootx64.efi 2>/dev/null || true
    $SUDO mcopy -i "$EFI_IMG" "$STAGING/boot/grub/grub.cfg" ::EFI/BOOT/grub.cfg 2>/dev/null || true
fi

# Build the ISO
echo "  Running xorriso with BIOS/UEFI hybrid boot..."
if [ -n "$HYBRID_MBR" ] && [ -f "$STAGING/boot/grub/eltorito.img" ]; then
    $SUDO xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "TUBE_OS" \
        -output "$ISO_OUTPUT" \
        -isohybrid-mbr "$HYBRID_MBR" \
        -b boot/grub/eltorito.img \
        -c boot/grub/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING"
else
    $SUDO xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "TUBE_OS" \
        -output "$ISO_OUTPUT" \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING"
fi

# Also create BIOS boot image if refind
if [ "$BOOTLOADER" = "refind" ]; then
    echo "  Adding rEFInd EFI image..."
    if [ -f "$ROOTFS_TARGET/boot/refind/refind_"*".efi" 2>/dev/null ]; then
        $SUDO cp "$ROOTFS_TARGET"/boot/refind/refind_*x86_64.efi "$STAGING/boot/grub/efi.img" 2>/dev/null || true
    fi
fi

ISO_SIZE=$(du -h "$ISO_OUTPUT" 2>/dev/null | cut -f1)

echo ""
echo "============================================="
echo "  Tube OS ISO built successfully!"
echo "  File: $ISO_OUTPUT"
echo "  Size: $ISO_SIZE"
echo "============================================="
