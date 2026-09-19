#!/bin/bash
# ==============================================================================
# Tube OS - ISO Builder (Fast Iteration & Incremental Build Engine)
# ==============================================================================
# Builds Tube OS ISO images (Debian and Arch editions).
# Optimized for ultra-fast iteration and incremental rebuilds.
#
# Usage:
#   ./tubeos/build-tubeos.sh [--arch] [--debian] [--grub] [--refind] [--local]
#                           [--quick|-q] [--incremental|-i] [--skip-pkg]
#                           [--clean-base] [--clean-target]
#
# Fast Iteration Options:
#   --quick, --fast, -q   ⚡ Ultra-fast developer iteration mode:
#                           - Reuses existing configured rootfs target
#                           - Incrementally rebuilds only modified local packages
#                           - Uses high-speed parallel SquashFS compression (zstd -3)
#   --incremental, -i     ⚡ Check and rebuild only modified packages
#   --skip-pkg, --pack-only Skip local package building, reuse existing .pkg.tar.zst / .deb
#   --clean-target        Wipe and reconstruct rootfs target from base
#   --clean-base          Force re-download of base system
#   --comp-level <1-19>   Set custom zstd compression level (default: 3 in quick, 15 normal)
#   --threads, -j <N>     Set parallel build/compression threads (default: $(nproc))
#   --arch                Build Arch edition (includes Plasma Bigscreen) [default]
#   --debian              Build Debian edition (headless, dashboard only)
#   --grub                Use GRUB bootloader [default]
#   --refind              Use rEFInd bootloader
#   --local               Build local packages before building ISO
# ==============================================================================

set -e

ORIGINAL_ARGS=("$@")

# ==============================================================================
# Parse arguments
# ==============================================================================
DISTRO="arch"
BOOTLOADER="grub"
USE_LOCAL=true
SKIP_PKG_BUILD=false
INCREMENTAL_PKG_BUILD=false
QUICK_MODE=false
CLEAN_BASE=false
CLEAN_TARGET=false
BRANCH="stable"
COMPRESSION_LEVEL=""
BUILD_PROCESSORS=$(nproc 2>/dev/null || echo 4)

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
        --grub)
            BOOTLOADER="grub"
            shift
            ;;
        --refind)
            BOOTLOADER="refind"
            shift
            ;;
        --local|--local-pkgs|--local-debs)
            USE_LOCAL=true
            shift
            ;;
        --incremental|-i|--smart|--smart-build)
            USE_LOCAL=true
            INCREMENTAL_PKG_BUILD=true
            shift
            ;;
        --skip-pkg|--skip-build|--pack-only|--skip-all)
            USE_LOCAL=true
            SKIP_PKG_BUILD=true
            shift
            ;;
        --quick|--fast|-q)
            QUICK_MODE=true
            USE_LOCAL=true
            INCREMENTAL_PKG_BUILD=true
            shift
            ;;
        --clean-base)
            CLEAN_BASE=true
            shift
            ;;
        --clean-target|--clean-rootfs|--rebuild-rootfs)
            CLEAN_TARGET=true
            shift
            ;;
        --comp-level|-c)
            COMPRESSION_LEVEL="$2"
            shift 2
            ;;
        --threads|-j)
            BUILD_PROCESSORS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Tube OS - ISO Builder"
            echo "Usage: ./tubeos/build-tubeos.sh [options]"
            echo ""
            echo "Options:"
            echo "  --quick, --fast, -q   ⚡ Ultra-fast developer iteration mode"
            echo "  --incremental, -i     ⚡ Check and rebuild only modified packages"
            echo "  --skip-pkg, --pack-only Skip local package building"
            echo "  --arch                Build Arch edition (Plasma Bigscreen) [default]"
            echo "  --debian              Build Debian edition (headless, dashboard only)"
            echo "  --grub                Use GRUB bootloader [default]"
            echo "  --refind              Use rEFInd bootloader"
            echo "  --clean-target        Wipe and reconstruct rootfs target from base"
            echo "  --clean-base          Force re-download of base system"
            echo "  --comp-level <1-19>   Set zstd compression level"
            echo "  --threads, -j <N>     Set parallel build threads (default: $(nproc))"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set default compression level based on mode
if [ -z "$COMPRESSION_LEVEL" ]; then
    if $QUICK_MODE; then
        COMPRESSION_LEVEL=3
    else
        COMPRESSION_LEVEL=15
    fi
fi

# ==============================================================================
# Paths
# ==============================================================================
REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SCRIPT")"

if [ "$(basename "$REAL_DIR")" = "tubeos" ]; then
    ISO_DIR="$(cd "$REAL_DIR/.." && pwd)"
else
    ISO_DIR="$REAL_DIR"
fi
PULSAR_ROOT="$(cd "$ISO_DIR/.." && pwd)"
PKG_DIR="$PULSAR_ROOT/PKG"
BUILD_DIR="$ISO_DIR/build"

# ==============================================================================
# Auto-Elevation to Root (pkexec / sudo)
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "🔐 Tube OS Builder requires superuser privileges."
    echo "Re-executing with pkexec..."
    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        exec pkexec "$REAL_SCRIPT" "${ORIGINAL_ARGS[@]}"
    else
        exec sudo "$REAL_SCRIPT" "${ORIGINAL_ARGS[@]}"
    fi
fi

unset XDG_RUNTIME_DIR
export HOME="/root"
SUDO=""

ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-tubeos-$DISTRO"
ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-tubeos-$DISTRO"
PACMAN_CACHE_DIR="$BUILD_DIR/pacman-cache"
ISO_OUTPUT="$BUILD_DIR/tubeos-$BRANCH-$DISTRO-$BOOTLOADER.iso"
PACKAGE_LIST="$ISO_DIR/configs/base-tubeos-$DISTRO.list"
CHROOT_BIN="$(command -v chroot || echo /usr/sbin/chroot)"

# Original user for makepkg (cannot run as root)
ORIGINAL_USER=""
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ORIGINAL_USER="$SUDO_USER"
elif [ -n "$PKEXEC_UID" ] && [ "$PKEXEC_UID" != "0" ]; then
    ORIGINAL_USER=$(id -un "$PKEXEC_UID" 2>/dev/null || true)
fi

if [ -z "$ORIGINAL_USER" ] || [ "$ORIGINAL_USER" = "root" ]; then
    ORIGINAL_USER=$(stat -c '%U' "$PULSAR_ROOT" 2>/dev/null || echo "jaime")
fi

run_as_user() {
    if [ "$ORIGINAL_USER" != "root" ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$ORIGINAL_USER" -- "$@"
        else
            sudo -u "$ORIGINAL_USER" "$@"
        fi
    else
        "$@"
    fi
}

echo "============================================="
echo "  Tube OS ISO Builder (Fast Engine)"
echo "  Edition: $DISTRO | Bootloader: $BOOTLOADER"
echo "  Quick Mode: $QUICK_MODE | Incremental: $INCREMENTAL_PKG_BUILD"
echo "  Compression: zstd lvl $COMPRESSION_LEVEL | Threads: $BUILD_PROCESSORS"
echo "  Running as root (User: $ORIGINAL_USER)"
echo "============================================="

# ==============================================================================
# Preflight cleanup & Safe Unmount
# ==============================================================================
unmount_tree() {
    local target_dir="$1"
    [ -z "$target_dir" ] && return 0
    [ ! -d "$target_dir" ] && return 0
    awk '$2 ~ "^'"$target_dir"'/" || $2 == "'"$target_dir"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        umount -l "$mp" 2>/dev/null || true
    done
}

cleanup() {
    echo "Cleaning chroot mounts safely..."
    unmount_tree "$ROOTFS_TARGET"
    unmount_tree "$ROOTFS_BASE"
    if [ -n "${STAGING:-}" ]; then
        unmount_tree "$STAGING"
    fi
    awk '$2 ~ "^'"$BUILD_DIR"'/" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        umount -l "$mp" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM
cleanup

mkdir -p "$BUILD_DIR" "$PACMAN_CACHE_DIR" "$BUILD_DIR/local-packages-tubeos"
chown -R "$ORIGINAL_USER:" "$PACMAN_CACHE_DIR" "$BUILD_DIR/local-packages-tubeos" 2>/dev/null || true

# Clean base if requested or if corrupt/incomplete
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/usr" ]; }; then
    echo "  Incomplete or corrupt base cache detected. Cleaning base..."
    rm -rf "$ROOTFS_BASE"
fi

if $CLEAN_BASE && [ -d "$ROOTFS_BASE" ]; then
    echo "Cleaning base cache..."
    rm -rf "$ROOTFS_BASE"
fi

# Determine if we can reuse the existing rootfs target for instant rebuilds
REUSE_TARGET=false
if $QUICK_MODE && [ -d "$ROOTFS_TARGET/etc" ] && [ -d "$ROOTFS_TARGET/usr" ] && ! $CLEAN_TARGET && ! $CLEAN_BASE; then
    echo "⚡ [QUICK MODE] Reusing existing configured rootfs target: $ROOTFS_TARGET"
    REUSE_TARGET=true
else
    if [ -d "$ROOTFS_TARGET" ]; then
        echo "  Preparing fresh rootfs target..."
        rm -rf "$ROOTFS_TARGET"
    fi
fi

# ==============================================================================
# Helper: Check if package needs rebuild (Incremental compilation)
# ==============================================================================
should_rebuild_arch_pkg() {
    local pkg="$1"
    local pkgbuild_dir="$PKGBUILDS_DIR/$pkg"
    local local_pkgs_dir="$LOCAL_PKGS_DIR"
    local src_dir="$PKG_DIR/$pkg"

    local existing_pkg
    existing_pkg=$(ls -t "$local_pkgs_dir"/${pkg}-[0-9]*.pkg.tar.zst 2>/dev/null | head -n 1)
    [ -z "$existing_pkg" ] && return 0

    if ! $INCREMENTAL_PKG_BUILD; then
        return 0
    fi

    local pkg_mtime
    pkg_mtime=$(stat -c %Y "$existing_pkg" 2>/dev/null || echo 0)

    # Check PKGBUILD directory
    local newest_pkgbuild
    newest_pkgbuild=$(find "$pkgbuild_dir" -type f -exec stat -c %Y {} + 2>/dev/null | sort -nr | head -n 1)
    if [ -n "$newest_pkgbuild" ] && [ "$newest_pkgbuild" -gt "$pkg_mtime" ]; then
        return 0
    fi

    # Check source directory
    if [ -d "$src_dir" ]; then
        local newest_src
        newest_src=$(find "$src_dir" -type f -not -path "*/.git/*" -exec stat -c %Y {} + 2>/dev/null | sort -nr | head -n 1)
        if [ -n "$newest_src" ] && [ "$newest_src" -gt "$pkg_mtime" ]; then
            return 0
        fi
    fi

    return 1
}

# ==============================================================================
# STEP 1: Build local packages (--local mode)
# ==============================================================================
if $USE_LOCAL; then
    echo ""
    echo ">>> STEP 1: Building local packages..."

    if [ "$DISTRO" = "arch" ]; then
        PKGBUILDS_DIR="$PKG_DIR/arch/pkgbuilds"
        LOCAL_PKGS_DIR="$BUILD_DIR/local-packages-tubeos"
        mkdir -p "$LOCAL_PKGS_DIR"
        chown -R "$ORIGINAL_USER:" "$LOCAL_PKGS_DIR" 2>/dev/null || true

        TUBEOS_PKGS="tubeos-branding tubeos-plymouth dockermigrate tube-os-dash tubeos-installer tubeos-ui"

        if $SKIP_PKG_BUILD; then
            echo "⚡ [SKIP-PKG] Reusing pre-built packages in $LOCAL_PKGS_DIR..."
        else
            for pkg in $TUBEOS_PKGS; do
                PKGBUILD_DIR="$PKGBUILDS_DIR/$pkg"
                if [ ! -d "$PKGBUILD_DIR" ]; then
                    echo "  SKIP: $pkg (no PKGBUILD found at $PKGBUILD_DIR)"
                    continue
                fi

                if should_rebuild_arch_pkg "$pkg"; then
                    echo "  🔨 Building $pkg..."
                    run_as_user bash -c "cd '$PKGBUILD_DIR' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -cfd --noconfirm --nosign 2>&1" || {
                        echo "  WARN: $pkg build failed, continuing..."
                    }
                else
                    echo "  ⚡ SKIP (up-to-date): $pkg"
                fi
            done
        fi

        # Remove debug packages
        rm -f "$LOCAL_PKGS_DIR"/*-debug-*.pkg.tar.zst 2>/dev/null || true

        # Deduplicate: keep newest version of each package
        echo "  Deduplicating packages..."
        cd "$LOCAL_PKGS_DIR"
        for pkg in $TUBEOS_PKGS; do
            if ls ${pkg}-[0-9]*.pkg.tar.zst &>/dev/null; then
                newest=$(ls -t ${pkg}-[0-9]*.pkg.tar.zst | head -1)
                for f in ${pkg}-[0-9]*.pkg.tar.zst; do
                    [ "$f" != "$newest" ] && rm -f "$f" "$f.sig" 2>/dev/null
                done
            fi
        done

        PKG_COUNT=$(ls "$LOCAL_PKGS_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)
        echo "  Ready packages: $PKG_COUNT in $LOCAL_PKGS_DIR"

    else
        # --- Debian: build with dpkg-deb ---
        LOCAL_DEBS_DIR="$BUILD_DIR/local-debs-tubeos"
        mkdir -p "$LOCAL_DEBS_DIR"
        chown -R "$ORIGINAL_USER:" "$LOCAL_DEBS_DIR" 2>/dev/null || true

        TUBEOS_PKGS="tubeos-branding tubeos-plymouth dockermigrate tube-os-dash tubeos-installer tubeos-ui"

        if $SKIP_PKG_BUILD; then
            echo "⚡ [SKIP-PKG] Reusing pre-built debs in $LOCAL_DEBS_DIR..."
        else
            for pkg in $TUBEOS_PKGS; do
                PKG_SRC="$PKG_DIR/$pkg"
                if [ ! -d "$PKG_SRC/DEBIAN" ]; then
                    echo "  SKIP: $pkg (no DEBIAN/control at $PKG_SRC)"
                    continue
                fi

                PKG_VER=$(grep "^Version:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')
                PKG_NAME=$(grep "^Package:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')
                ARCH=$(grep "^Architecture:" "$PKG_SRC/DEBIAN/control" | awk '{print $2}')
                DEB_FILE="${LOCAL_DEBS_DIR}/${PKG_NAME}_${PKG_VER}_${ARCH}.deb"

                if $INCREMENTAL_PKG_BUILD && [ -f "$DEB_FILE" ]; then
                    deb_mtime=$(stat -c %Y "$DEB_FILE" 2>/dev/null || echo 0)
                    src_mtime=$(find "$PKG_SRC" -type f -exec stat -c %Y {} + 2>/dev/null | sort -nr | head -n 1)
                    if [ -n "$src_mtime" ] && [ "$src_mtime" -le "$deb_mtime" ]; then
                        echo "  ⚡ SKIP (up-to-date): $pkg"
                        continue
                    fi
                fi

                echo "  🔨 Building $pkg..."
                dpkg-deb --build --root-owner-group "$PKG_SRC" "$DEB_FILE" >/dev/null 2>&1 || \
                dpkg-deb --build "$PKG_SRC" "$DEB_FILE" >/dev/null 2>&1 || {
                    echo "  WARN: $pkg build failed"
                }
            done
        fi

        DEB_COUNT=$(ls "$LOCAL_DEBS_DIR"/*.deb 2>/dev/null | wc -l)
        echo "  Ready packages: $DEB_COUNT in $LOCAL_DEBS_DIR"
    fi
fi

# ==============================================================================
# STEP 2: Bootstrap base system
# ==============================================================================
echo ""
echo ">>> STEP 2: Setting up rootfs base and target..."

if ! $REUSE_TARGET; then
    if [ "$DISTRO" = "arch" ]; then
        if [ ! -d "$ROOTFS_BASE/etc" ]; then
            if [ -d "$BUILD_DIR/rootfs-base-stable-arch" ] && [ -d "$BUILD_DIR/rootfs-base-stable-arch/etc" ]; then
                echo "  Reusing local virgin Arch base cache..."
                cp -a "$BUILD_DIR/rootfs-base-stable-arch" "$ROOTFS_BASE"
            else
                echo "  Downloading Arch Linux base..."
                mkdir -p "$ROOTFS_BASE"
                CLEAN_PACMAN_CONF="/tmp/tubeos-pacman-$$.conf"
                cp /etc/pacman.conf "$CLEAN_PACMAN_CONF" 2>/dev/null || true
                if ! grep -q '\[inled\]' "$CLEAN_PACMAN_CONF" 2>/dev/null; then
                    cat >> "$CLEAN_PACMAN_CONF" << 'REPOEOF'

[inled]
SigLevel = Optional TrustAll
Server = https://apt.inled.es/arch/
REPOEOF
                fi
                mkdir -p "$ROOTFS_BASE/etc/pacman.d"
                if [ -d /etc/pacman.d/gnupg ]; then
                    cp -a /etc/pacman.d/gnupg "$ROOTFS_BASE/etc/pacman.d/"
                fi
                BASE_PKGS=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -vE 'tubeos-|tube-os-|dockermigrate|plasma-|kodi|python-' | tr '\n' ' ')
                pacstrap -K -M -c -C "$CLEAN_PACMAN_CONF" "$ROOTFS_BASE" $BASE_PKGS
                rm -f "$CLEAN_PACMAN_CONF"
            fi
        fi
        echo "  Copying base rootfs to target..."
        cp -a --reflink=auto "$ROOTFS_BASE" "$ROOTFS_TARGET" 2>/dev/null || cp -a "$ROOTFS_BASE" "$ROOTFS_TARGET"
    else
        if [ ! -d "$ROOTFS_BASE/etc" ]; then
            if [ -d "$BUILD_DIR/rootfs-base-stable-debian" ] && [ -d "$BUILD_DIR/rootfs-base-stable-debian/etc" ]; then
                echo "  Reusing local virgin Debian base cache..."
                cp -a "$BUILD_DIR/rootfs-base-stable-debian" "$ROOTFS_BASE"
            else
                echo "  Downloading Debian base (trixie)..."
                mkdir -p "$ROOTFS_BASE"
                BASE_PKGS=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -vE 'tubeos-|tube-os-|dockermigrate' | paste -sd, -)
                debootstrap --include="$BASE_PKGS" trixie "$ROOTFS_BASE" http://deb.debian.org/debian
            fi
        fi
        echo "  Copying base rootfs to target..."
        cp -a --reflink=auto "$ROOTFS_BASE" "$ROOTFS_TARGET" 2>/dev/null || cp -a "$ROOTFS_BASE" "$ROOTFS_TARGET"
    fi
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

# Pacman cache bind-mount for speed
if [ "$DISTRO" = "arch" ]; then
    mkdir -p "$ROOTFS_TARGET/var/cache/pacman/pkg" "$PACMAN_CACHE_DIR"
    $SUDO mount --bind "$PACMAN_CACHE_DIR" "$ROOTFS_TARGET/var/cache/pacman/pkg" 2>/dev/null || true
elif [ "$DISTRO" = "debian" ]; then
    $SUDO tee "$ROOTFS_TARGET/usr/sbin/policy-rc.d" > /dev/null << 'POLEOF'
#!/bin/sh
exit 101
POLEOF
    $SUDO chmod +x "$ROOTFS_TARGET/usr/sbin/policy-rc.d" 2>/dev/null || true
fi

# DNS
echo "nameserver 8.8.8.8" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

# Plymouth theme dir (satisfy hooks)
$SUDO mkdir -p "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos"
$SUDO ln -sf . "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos/images" 2>/dev/null || true

# ==============================================================================
# STEP 4: Install Tube OS packages
# ==============================================================================
echo ""
echo ">>> STEP 4: Installing/Updating Tube OS packages..."

if [ "$DISTRO" = "arch" ]; then
    $SUDO tee "$ROOTFS_TARGET/etc/pacman.conf" > /dev/null << 'PACCONF'
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Optional TrustAll
LocalFileSigLevel = Optional
NoProgressBar
ParallelDownloads = 8

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
    mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/" 2>/dev/null || true

        # Synchronize and install base dependencies from package list
        ALL_DEPS=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -vE 'tubeos-|tube-os-|dockermigrate' | tr '\n' ' ')
        "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            pacman-key --init 2>/dev/null || true
            pacman-key --populate archlinux 2>/dev/null || true
            pacman -Sy --noconfirm 2>/dev/null || true
            pacman -S --noconfirm --needed --overwrite '*' $ALL_DEPS plymouth archiso uvicorn python-fastapi python-qrcode || true
        "

    if $USE_LOCAL; then
        echo "  Installing/updating local packages..."
        LOCAL_PKGS_DIR="$BUILD_DIR/local-packages-tubeos"
        if [ -d "$LOCAL_PKGS_DIR" ] && ls "$LOCAL_PKGS_DIR"/*.pkg.tar.zst &>/dev/null; then
            mkdir -p "$ROOTFS_TARGET/tmp/packages"
            cp "$LOCAL_PKGS_DIR"/*.pkg.tar.zst "$ROOTFS_TARGET/tmp/packages/"
            rm -f "$ROOTFS_TARGET/tmp/packages"/*-debug-*.pkg.tar.zst 2>/dev/null || true

            TUBEOS_PKG_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate' | tr '\n' ' ')

            "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                pacman -U --noconfirm --overwrite '*' /tmp/packages/*.pkg.tar.zst 2>/dev/null || pacman -U --noconfirm --nodeps --overwrite '*' /tmp/packages/*.pkg.tar.zst 2>/dev/null || true
                pacman -S --noconfirm --needed --overwrite '*' $TUBEOS_PKG_NAMES 2>/dev/null || true
            "
            rm -rf "$ROOTFS_TARGET/tmp/packages"
        fi
    else
        echo "  Installing from repos..."
        TUBEOS_PKG_NAMES=$(grep -v '^#' "$PACKAGE_LIST" | grep -v '^$' | grep -E 'tubeos-|tube-os-|dockermigrate' | tr '\n' ' ')
        "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            pacman -S --noconfirm --needed --overwrite '*' $TUBEOS_PKG_NAMES 2>/dev/null || true
        "
    fi

    if ! $REUSE_TARGET; then
        # Bootloader
        if [ "$BOOTLOADER" = "grub" ]; then
            "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && pacman -S --noconfirm --needed --overwrite '*' grub os-prober efibootmgr"
        else
            "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && pacman -S --noconfirm --needed --overwrite '*' refind efibootmgr grub os-prober"
        fi
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
                apt-get install -y --no-install-recommends /tmp/packages/*.deb 2>/dev/null || dpkg -i --force-depends /tmp/packages/*.deb 2>/dev/null || true
                apt-get install -f -y --no-install-recommends 2>/dev/null || apt-get install -f -y 2>/dev/null || true
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
            apt-get install -y -qq grub-pc-bin grub-efi-amd64-bin grub-efi-amd64 os-prober efibootmgr
        "
    else
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq refind efibootmgr grub-pc-bin grub-efi-amd64-bin grub-efi-amd64 os-prober
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

# Configure Avahi mDNS daemon and services
$SUDO mkdir -p "$ROOTFS_TARGET/etc/avahi/services"
$SUDO tee "$ROOTFS_TARGET/etc/avahi/avahi-daemon.conf" > /dev/null << 'AVAHIEOF'
[server]
host-name=tubeos
domain-name=local
use-ipv4=yes
use-ipv6=yes
check-response-ttl=no
use-iff-running=yes

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=yes
publish-domain=yes

[reflector]
enable-reflector=no

[rlimits]
AVAHIEOF

$SUDO tee "$ROOTFS_TARGET/etc/avahi/services/tubeos-http.service" > /dev/null << 'AVAHISERV'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Tube OS Web on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
AVAHISERV

$SUDO tee "$ROOTFS_TARGET/etc/avahi/services/dockermigrate.service" > /dev/null << 'AVAHISERV'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">DockerMigrate on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>8070</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
AVAHISERV

# Ensure installer, dockermigrate, and dashboard systemd services & binaries exist
$SUDO mkdir -p "$ROOTFS_TARGET/usr/lib/systemd/system" "$ROOTFS_TARGET/usr/bin" "$ROOTFS_TARGET/etc/tubeos" "$ROOTFS_TARGET/etc/docker"
$SUDO cp "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/tubeos-installer.service" "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true
$SUDO cp "$PKG_DIR/tubeos-installer/usr/share/tubeos-installer/tubeos-ootb.service" "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true

# Copy dockermigrate
if [ -f "$PKG_DIR/dockermigrate/usr/bin/dockermigrate" ]; then
    $SUDO cp -f "$PKG_DIR/dockermigrate/usr/bin/dockermigrate" "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
    $SUDO ln -sf dockermigrate "$ROOTFS_TARGET/usr/bin/dockmigrate" 2>/dev/null || true
    $SUDO chmod 755 "$ROOTFS_TARGET/usr/bin/dockermigrate" 2>/dev/null || true
fi
if [ -f "$PKG_DIR/dockermigrate/usr/lib/systemd/system/dockermigrate.service" ]; then
    $SUDO cp -f "$PKG_DIR/dockermigrate/usr/lib/systemd/system/dockermigrate.service" "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true
    $SUDO ln -sf dockermigrate.service "$ROOTFS_TARGET/usr/lib/systemd/system/dockmigrate.service" 2>/dev/null || true
fi

# Copy dashboard binaries, data, and configs
if [ -d "$PKG_DIR/tube-os-dash/usr/bin" ]; then
    $SUDO cp -f "$PKG_DIR/tube-os-dash/usr/bin/"* "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
    $SUDO chmod 755 "$ROOTFS_TARGET/usr/bin/tubeos"* 2>/dev/null || true
fi
if [ -d "$PKG_DIR/tube-os-dash/etc/tubeos" ]; then
    $SUDO cp -rf "$PKG_DIR/tube-os-dash/etc/tubeos/"* "$ROOTFS_TARGET/etc/tubeos/" 2>/dev/null || true
fi
if [ -d "$PKG_DIR/tube-os-dash/var/lib/tubeos" ]; then
    $SUDO mkdir -p "$ROOTFS_TARGET/var/lib/tubeos"
    $SUDO cp -rf "$PKG_DIR/tube-os-dash/var/lib/tubeos/"* "$ROOTFS_TARGET/var/lib/tubeos/" 2>/dev/null || true
fi
if [ -d "$PKG_DIR/tubeos-branding/etc/xdg/autostart" ]; then
    $SUDO mkdir -p "$ROOTFS_TARGET/etc/xdg/autostart"
    $SUDO cp -rf "$PKG_DIR/tubeos-branding/etc/xdg/autostart/"* "$ROOTFS_TARGET/etc/xdg/autostart/" 2>/dev/null || true
fi
if [ -d "$PKG_DIR/tube-os-dash/usr/lib/systemd/system" ]; then
    $SUDO cp -f "$PKG_DIR/tube-os-dash/usr/lib/systemd/system/"* "$ROOTFS_TARGET/usr/lib/systemd/system/" 2>/dev/null || true
fi
if [ -d "$PKG_DIR/tube-os-dash/usr/lib/tmpfiles.d" ]; then
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/lib/tmpfiles.d"
    $SUDO cp -f "$PKG_DIR/tube-os-dash/usr/lib/tmpfiles.d/"* "$ROOTFS_TARGET/usr/lib/tmpfiles.d/" 2>/dev/null || true
fi

# Configure live Docker to use vfs driver (overlay-on-overlayfs safe for live ISO media)
$SUDO tee "$ROOTFS_TARGET/etc/docker/daemon.json" > /dev/null << 'DOCKERCONF'
{
  "log-driver": "journald",
  "storage-driver": "vfs"
}
DOCKERCONF

# Disable graphical target, enable multi-user, networking, avahi (mDNS), docker, dockermigrate, and installer
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    mkdir -p /var/log/casaos /var/log/tubeos /var/lib/tubeos/conf /var/lib/tubeos/db /var/lib/tubeos/apps /var/lib/tubeos/appstore /run/tubeos /var/run/tubeos /var/run/rclone /usr/share/tubeos/shell 2>/dev/null || true
    systemctl set-default multi-user.target 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
    systemctl enable dockermigrate 2>/dev/null || true
    systemctl enable tubeos-installer 2>/dev/null || true

    # Configure static TTY1 autologin for live root session
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'GETTYEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\\\u' --noclear --autologin root %I \$TERM
Type=idle
GETTYEOF

    # Configure console welcome banner on login
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/tubeos-welcome.sh << 'WELCOMEOF'
#!/bin/sh
if [ -t 1 ] && [ \"\$SHLVL\" -le 2 ]; then
    echo \"\"
    echo -e \"\033[0;36m _____             _____ _____ \033[0m\"
    echo -e \"\033[0;36m|     |___ ___ ___|     |   __|\033[0m\"
    echo -e \"\033[0;36m|   --| .'|_ -| .'|  |  |__   |\033[0m\"
    echo -e \"\033[0;36m|_____|__,|___|__,|_____|_____|\033[0m\"
    echo -e \"       \033[1;32mTube OS Live Console\033[0m\"
    echo \"\"
    IP=\$(ip -4 addr show | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    echo -e \"  \033[1;33mWeb Installer / UI:\033[0m http://\${IP:-tubeos.local} (or http://tubeos.local)\"
    echo -e \"  \033[1;33mDockerMigrate:\033[0m      http://\${IP:-tubeos.local}:8070 (or http://tubeos.local:8070)\"
    echo \"\"
fi
WELCOMEOF
    chmod +x /etc/profile.d/tubeos-welcome.sh

    # Allow blank password login in PAM
    if [ -f /etc/pam.d/common-auth ]; then
        sed -i 's/pam_unix.so/pam_unix.so nullok/' /etc/pam.d/common-auth 2>/dev/null || true
    fi
" || true

# Install Plymouth theme
if [ -f "$ROOTFS_TARGET/usr/share/plymouth/themes/tubeos/tubeos.plymouth" ]; then
    "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        plymouth-set-default-theme tubeos 2>/dev/null || true
    " || true
    if [ "$DISTRO" = "debian" ]; then
        echo "  Updating Debian initramfs with TubeOS Plymouth theme..."
        "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export DEBIAN_FRONTEND=noninteractive
            update-initramfs -u 2>/dev/null || true
        " || true
    fi
fi

# Live Arch initramfs configuration (archiso hooks)
if [ "$DISTRO" = "arch" ]; then
    echo "  Configuring Arch initramfs with archiso hooks..."
    "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        pacman -S --noconfirm --needed archiso 2>/dev/null || true
    " || true

    mkdir -p "$ROOTFS_TARGET/etc/mkinitcpio.conf.d"
    echo 'HOOKS=(base udev modconf keyboard kms plymouth archiso archiso_loop_mnt block filesystems)' > "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/archiso.conf"
    echo 'MODULES=(i915 amdgpu radeon nouveau virtio_gpu bochs vboxvideo vmwgfx 9p 9pnet 9pnet_virtio virtio_pci virtio_blk)' > "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/kms.conf"

    # Pixmap logo for plymouth hook in mkinitcpio
    mkdir -p "$ROOTFS_TARGET/usr/share/pixmaps"
    if [ -f "$ROOTFS_TARGET/usr/share/tubeos/branding/tube-os-512.png" ]; then
        cp "$ROOTFS_TARGET/usr/share/tubeos/branding/tube-os-512.png" "$ROOTFS_TARGET/usr/share/pixmaps/archlinux-logo.png" 2>/dev/null || true
    fi

    echo "  Generating live initramfs (with archiso)..."
    "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        mkinitcpio -P
    "
fi

# Unlock root account without password for live session and emergency login
"$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    passwd -d root 2>/dev/null || true
    passwd -u root 2>/dev/null || true
    usermod -p '' root 2>/dev/null || true
" || true

$SUDO rm -f "$ROOTFS_TARGET/usr/sbin/policy-rc.d" 2>/dev/null || true

# ==============================================================================
# STEP 7: Copy Kernel & Initrd to Staging
# ==============================================================================
echo ""
echo ">>> STEP 7: Preparing live media staging..."

# Create staging area
STAGING="$BUILD_DIR/tubeos-iso-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/live"
mkdir -p "$STAGING/boot/grub"
mkdir -p "$STAGING/EFI/BOOT"
mkdir -p "$STAGING/isolinux"

if [ "$DISTRO" = "arch" ]; then
    KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
    INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -n 1)
    cp "$KERNEL_FILE" "$STAGING/live/vmlinuz"
    cp "$INITRD_FILE" "$STAGING/live/initrd.img"

    echo "  Cleaning live hooks and regenerating standard initramfs for installed rootfs..."
    rm -f "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/archiso.conf"
    "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        mkinitcpio -P
    "

    KERNEL_PARAMS="archisobasedir=live archisolabel=TUBE_OS cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes copytoram=n plymouth.use-simpledrm=0 quiet splash loglevel=3 --"
    SAFE_PARAMS="archisobasedir=live archisolabel=TUBE_OS cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 --"
else
    cp "$ROOTFS_TARGET/boot/vmlinuz-"* "$STAGING/live/vmlinuz" 2>/dev/null || true
    cp "$ROOTFS_TARGET/boot/initrd.img-"* "$STAGING/live/initrd.img" 2>/dev/null || \
    cp "$ROOTFS_TARGET/boot/initrd.img" "$STAGING/live/initrd.img" 2>/dev/null || true
    KERNEL_PARAMS="boot=live components locales=en_US.UTF-8 username=live autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 noprompt --"
    SAFE_PARAMS="boot=live components locales=en_US.UTF-8 username=live autologin cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 noprompt --"
fi

# ==============================================================================
# STEP 8: Cleanup chroot mounts
# ==============================================================================
echo ""
echo ">>> STEP 8: Unmounting chroot..."
cleanup

# ==============================================================================
# STEP 9: Build SquashFS and ISO
# ==============================================================================
echo ""
echo ">>> STEP 9: Building SquashFS & Bootable ISO..."

echo "  Creating squashfs image (zstd level $COMPRESSION_LEVEL, $BUILD_PROCESSORS threads)..."
if [ "$DISTRO" = "arch" ]; then
    mkdir -p "$STAGING/live/x86_64" "$STAGING/arch/x86_64"
    SQUASHFS="$STAGING/live/x86_64/airootfs.sfs"
    mksquashfs "$ROOTFS_TARGET" "$SQUASHFS" \
        -comp zstd -Xcompression-level "$COMPRESSION_LEVEL" \
        -processors "$BUILD_PROCESSORS" -noappend \
        -e proc/* -e sys/* -e dev/* -e run/* -e tmp/* -e var/tmp/* -e var/log/* -e root/.bash_history
    ln -f "$SQUASHFS" "$STAGING/arch/x86_64/airootfs.sfs" 2>/dev/null || true
    ln -f "$SQUASHFS" "$STAGING/live/filesystem.squashfs" 2>/dev/null || true
else
    mkdir -p "$STAGING/live"
    SQUASHFS="$STAGING/live/filesystem.squashfs"
    if $QUICK_MODE; then
        mksquashfs "$ROOTFS_TARGET" "$SQUASHFS" \
            -comp zstd -Xcompression-level "$COMPRESSION_LEVEL" \
            -processors "$BUILD_PROCESSORS" -noappend \
            -e proc/* -e sys/* -e dev/* -e run/* -e tmp/* -e var/tmp/* -e var/log/* -e root/.bash_history
    else
        mksquashfs "$ROOTFS_TARGET" "$SQUASHFS" \
            -comp xz -b 1M -processors "$BUILD_PROCESSORS" -noappend \
            -e proc/* -e sys/* -e dev/* -e run/* -e tmp/* -e var/tmp/* -e var/log/* -e root/.bash_history
    fi
fi

# Prepare clean GRUB theme for ISO staging
echo "  Preparing modern graphical GRUB theme for ISO..."
$SUDO rm -rf "$STAGING/boot/grub/themes/Particle-circle-window"
$SUDO mkdir -p "$STAGING/boot/grub/themes/Particle-circle-window"

TMP_GRUB_STAGE="/tmp/tubeos-grub-theme-stage-$$"
$SUDO rm -rf "$TMP_GRUB_STAGE"
mkdir -p "$TMP_GRUB_STAGE"
git clone --depth=1 "https://github.com/Inled-Pulsar-OS/grub.theme" "$TMP_GRUB_STAGE/theme" >/dev/null 2>&1 || true

if [ -f "$TMP_GRUB_STAGE/theme/generate.sh" ]; then
    (cd "$TMP_GRUB_STAGE/theme" && ./generate.sh -d "$STAGING/boot/grub/themes" -t window -s 1080p >/dev/null 2>&1 || true)
fi

# Wallpaper background for GRUB
if [ -f "$PKG_DIR/pulsaros-sddm/Apple.Tahoe/pulsar-os-tahoe.png" ]; then
    if command -v magick >/dev/null 2>&1; then
        magick "$PKG_DIR/pulsaros-sddm/Apple.Tahoe/pulsar-os-tahoe.png" -quality 95 "$STAGING/boot/grub/themes/Particle-circle-window/background.jpg" 2>/dev/null || true
    elif command -v convert >/dev/null 2>&1; then
        convert "$PKG_DIR/pulsaros-sddm/Apple.Tahoe/pulsar-os-tahoe.png" -quality 95 "$STAGING/boot/grub/themes/Particle-circle-window/background.jpg" 2>/dev/null || true
    fi
fi

$SUDO rm -rf "$STAGING/boot/grub/themes/Particle-circle-window/icons"
$SUDO mkdir -p "$STAGING/boot/grub/themes/Particle-circle-window/icons"

if [ -f "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt" ]; then
    $SUDO sed -i '/\+ image {/,/}/d' "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt"
    $SUDO sed -i 's/icon_width = .*/icon_width = 0/' "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt"
    $SUDO sed -i 's/icon_height = .*/icon_height = 0/' "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt"
    $SUDO sed -i 's/item_icon_space = .*/item_icon_space = 0/' "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt"
    $SUDO sed -i 's/width = .*/width = 65%/' "$STAGING/boot/grub/themes/Particle-circle-window/theme.txt"
fi

if [ -d "$TMP_GRUB_STAGE/theme/common" ]; then
    $SUDO cp -f "$TMP_GRUB_STAGE/theme/common"/*.pf2 "$STAGING/boot/grub/themes/Particle-circle-window/" 2>/dev/null || true
fi
$SUDO rm -rf "$TMP_GRUB_STAGE"

$SUDO mkdir -p "$STAGING/boot/grub/fonts"
if [ -f "/usr/share/grub/unicode.pf2" ]; then
    $SUDO cp "/usr/share/grub/unicode.pf2" "$STAGING/boot/grub/fonts/" 2>/dev/null || true
elif [ -f "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" ]; then
    $SUDO cp "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" "$STAGING/boot/grub/fonts/" 2>/dev/null || true
fi

# GRUB config
$SUDO tee "$STAGING/boot/grub/grub.cfg" > /dev/null << GRUBCFG
set default=0
set timeout=5

insmod all_video
insmod font
insmod gfxterm
insmod png
insmod jpeg
insmod gfxmenu

if loadfont /boot/grub/fonts/unicode.pf2; then
    set gfxmode=auto
    keep_gfxmode=keep
    terminal_output gfxterm
fi

if [ -f /boot/grub/themes/Particle-circle-window/theme.txt ]; then
    loadfont /boot/grub/themes/Particle-circle-window/terminus-12.pf2
    loadfont /boot/grub/themes/Particle-circle-window/terminus-14.pf2
    loadfont /boot/grub/themes/Particle-circle-window/terminus-16.pf2
    loadfont /boot/grub/themes/Particle-circle-window/terminus-18.pf2
    loadfont /boot/grub/themes/Particle-circle-window/unifont-16.pf2
    set theme=/boot/grub/themes/Particle-circle-window/theme.txt
fi

menuentry "Tube OS Live" --class tubeos --class os {
    linux /live/vmlinuz $KERNEL_PARAMS
    initrd /live/initrd.img
}

menuentry "Tube OS Live (safe mode - nomodeset)" --class tubeos --class os {
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
