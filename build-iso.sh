#!/bin/bash
# ==============================================================================
# Pulsar OS - Clean Chroot and Live ISO Builder
# ==============================================================================
# This script builds the clean chroot base file system for Pulsar OS,
# installs packages from the local builds or the APT repository, and packages
# everything into a bootable hybrid Live CD ISO image.
#
# Supports both Debian-based and Arch Linux editions.
#
# Este script construye el sistema de archivos base (chroot) de Pulsar OS,
# instala paquetes locales o desde el repositorio APT, y empaqueta todo en
# una imagen ISO booteable híbrida de Live CD.
#
# Usage / Uso:
#   ./build-iso.sh [--clean-base] [--local] [--arch]
#
# Options / Opciones:
#   --clean-base    Delete the base Debian cache and download it from scratch.
#                   Borra la caché base de Debian y la descarga de nuevo.
#   --local         Use local .deb packages from build/packages/ instead of the repo.
#                   Usa los paquetes .deb locales de build/packages/ en vez del repo.
#   --arch          Build Arch Linux edition instead of Debian.
#                   Construye la edición Arch Linux en vez de Debian.
#
# Safety / Seguridad:
#   By default the script NEVER installs packages on the host machine. If host
#   dependencies are missing it aborts with instructions. To allow host package
#   installation, run with ALLOW_HOST_INSTALL=true (dangerous on Arch hosts).
#   Por defecto el script NUNCA instala paquetes en el host. Si faltan dependencias
#   del host, aborta con instrucciones. Para autorizar la instalación en el host,
#   ejecuta con ALLOW_HOST_INSTALL=true (peligroso en hosts Arch).
# ==============================================================================

set -e

ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ISO_DIR"
BUILD_DIR="$ISO_DIR/build"

# Guardar argumentos originales para la auto-elevación antes de ser consumidos por shift
ORIGINAL_ARGS=("$@")

# ==============================================================================
# Parse Arguments / Parámetros
# ==============================================================================
CLEAN_BASE=false
USE_LOCAL_PKGS=true
if [ ! -d "$ISO_DIR/../PKG" ]; then
    USE_LOCAL_PKGS=false
fi
SKIP_PKG_BUILD=false
INCREMENTAL_PKG_BUILD=false
BOOTLOADER="grub" # Default bootloader is GRUB / El cargador por defecto es GRUB
BRANCH="stable"
WITH_NVIDIA=false
DISTRO="debian"   # Distribution: debian or arch / Distribución: debian o arch
MINIMAL=false       # Minimal ISO: trimmed package list for ~2-3GB target
PULSAR_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-base)
            CLEAN_BASE=true
            shift
            ;;
        --production|--remote)
            USE_LOCAL_PKGS=false
            shift
            ;;
        --local|--local-pkgs|--local-debs)
            USE_LOCAL_PKGS=true
            shift
            ;;
        --skip-all|--skip-pkg|--pack-only|--skip-build)
            USE_LOCAL_PKGS=true
            SKIP_PKG_BUILD=true
            shift
            ;;
        --incremental|-i|--rebuild-modified|--smart|--smart-build)
            USE_LOCAL_PKGS=true
            INCREMENTAL_PKG_BUILD=true
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
        --minimal)
            MINIMAL=true
            shift
            ;;
        --full)
            MINIMAL=false
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
        --version|-v)
            PULSAR_VERSION="$2"
            export PULSAR_VERSION
            shift 2
            ;;
        *)
            echo "❌ Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$BRANCH" != "stable" ] && [ "$BRANCH" != "forky" ] && [ "$BRANCH" != "rolling" ]; then
    echo "❌ Error: Branch must be 'stable', 'forky' or 'rolling'. Value received: $BRANCH"
    exit 1
fi

# ==============================================================================
# Detect distribution type from branch suffix or explicit flag
# ==============================================================================
if [ "$DISTRO" = "arch" ]; then
    echo "🏗️  Arch Mode Enabled | Building arch image"
fi

# ==============================================================================
# Check Host Dependencies / Comprobación de Dependencias del Host
# ==============================================================================
check_host_package_installed() {
    local pkg="$1"
    if command -v pacman >/dev/null 2>&1; then
        local arch_pkg="$pkg"
        case "$pkg" in
            grub-pc-bin|grub-efi-amd64-bin)
                arch_pkg="grub"
                ;;
            mtools)
                arch_pkg="mtools"
                ;;
            debian-archive-keyring)
                arch_pkg="debian-archive-keyring"
                ;;
        esac
        pacman -Qs "^${arch_pkg}$" >/dev/null 2>&1
        return $?
    elif command -v dpkg >/dev/null 2>&1; then
        dpkg -l | grep -q "^ii\s\+${pkg}\b" >/dev/null 2>&1
        return $?
    else
        return 0
    fi
}

MISSING_PACKAGES=()

# Check standard commands / Comprobar comandos estándar
if [ "$DISTRO" = "arch" ]; then
    CMDS=("pacstrap" "fakeroot" "rsync" "jq" "curl" "unzip" "wget" "mksquashfs" "xorriso" "sassc")
else
    CMDS=("mmdebstrap" "fakeroot" "rsync" "jq" "curl" "unzip" "wget" "mksquashfs" "xorriso" "sassc")
fi
if [ "$BOOTLOADER" = "grub" ]; then
    CMDS+=("grub-mkrescue")
fi

for cmd in "${CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$cmd")
    fi
done

# Command to package name mapping for special cases
# Casos especiales de mapeo comando -> paquete
if ! command -v convert >/dev/null 2>&1; then
    MISSING_PACKAGES+=("imagemagick")
fi

if ! command -v fuser >/dev/null 2>&1; then
    MISSING_PACKAGES+=("psmisc")
fi

if ! check_host_package_installed "mtools"; then
    MISSING_PACKAGES+=("mtools")
fi

if [ "$DISTRO" = "debian" ]; then
    if [ "$BOOTLOADER" = "grub" ]; then
        # We also need the BIOS and UEFI build files for grub-mkrescue
        # También necesitamos los archivos de construcción BIOS y UEFI para grub-mkrescue
        if ! check_host_package_installed "grub-pc-bin"; then
            MISSING_PACKAGES+=("grub-pc-bin")
        fi
        if ! check_host_package_installed "grub-efi-amd64-bin"; then
            MISSING_PACKAGES+=("grub-efi-amd64-bin")
        fi
    fi

    if ! command -v debootstrap >/dev/null 2>&1 && ! command -v mmdebstrap >/dev/null 2>&1; then
        MISSING_PACKAGES+=("debootstrap")
    fi

    if [ ! -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        MISSING_PACKAGES+=("debian-archive-keyring")
    fi
fi

# Install dependencies if they are missing / Instalar dependencias si faltan
if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    echo "⚠️ Essential dependencies detected to be missing from the host: ${MISSING_PACKAGES[*]}"
    echo "These tools are required for Pulsar OS build ($BOOTLOADER)."
    
    # SAFETY GUARD: never touch the host package manager by default on developer machines.
    if [ "$ALLOW_HOST_INSTALL" != "true" ] && [ "$GITHUB_ACTIONS" != "true" ] && [ "$CI" != "true" ]; then
        echo "❌ Missing host dependencies. They will NOT auto-install to protect your system."
        echo "   Manually install missing packages (e.g. sudo pacman -S ${MISSING_PACKAGES[*]})"
        echo "   or repeat the command with the variable ALLOW_HOST_INSTALL=true to authorize the installation. To install pacstrap use arch-install-scripts"
        exit 1
    fi
    
    # Auto-approve if in non-interactive environment (CI, pipeline, no TTY stdin)
    # Aprobación automática si estamos en un entorno no interactivo (CI, pipeline, sin TTY stdin)
    auto_install=false
    if [ "$GITHUB_ACTIONS" = "true" ] || [ ! -t 0 ]; then
        auto_install=true
    else
        read -p "Do you want to install the missing dependencies now? (y/n):" confirm
        confirm=$(echo "$confirm" | tr -d '\r')
        if [[ "$confirm" =~ ^[sSyY]$ ]] || [ -z "$confirm" ]; then
            auto_install=true
        fi
    fi
    
    if [ "$auto_install" = true ]; then
        # Detect package manager and install mapped packages
        pkg_manager=""
        if command -v pacman >/dev/null 2>&1; then
            pkg_manager="pacman"
        elif command -v apt-get >/dev/null 2>&1; then
            pkg_manager="apt"
        fi

        if [ -z "$pkg_manager" ]; then
            echo "❌ Error: A supported package manager (apt or pacman) was not detected."
            exit 1
        fi

        packages_to_install=()
        for item in "${MISSING_PACKAGES[@]}"; do
            case "$item" in
                mmdebstrap|debootstrap|fakeroot|rsync|jq|curl|unzip|wget|xorriso|imagemagick|psmisc|mtools|debian-archive-keyring|sassc)
                    packages_to_install+=("$item")
                    ;;
                mksquashfs)
                    packages_to_install+=("squashfs-tools")
                    ;;
                pacstrap)
                    packages_to_install+=("arch-install-scripts")
                    ;;
                grub-mkrescue)
                    if [ "$pkg_manager" = "pacman" ]; then
                        packages_to_install+=("grub")
                    else
                        packages_to_install+=("grub-common")
                    fi
                    ;;
                grub-pc-bin|grub-efi-amd64-bin)
                    if [ "$pkg_manager" = "apt" ]; then
                        packages_to_install+=("$item")
                    fi
                    ;;
                *)
                    packages_to_install+=("$item")
                    ;;
            esac
        done

        # Deduplicate
        packages_to_install=($(echo "${packages_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        if [ ${#packages_to_install[@]} -gt 0 ]; then
            echo "📥 Installing dependencies on the host using $pkg_manager..."
            if [ "$pkg_manager" = "pacman" ]; then
                # Separate official pacman packages from AUR packages
                pacman_official=()
                aur_packages=()
                for pkg in "${packages_to_install[@]}"; do
                    if pacman -Si "$pkg" >/dev/null 2>&1; then
                        pacman_official+=("$pkg")
                    else
                        aur_packages+=("$pkg")
                    fi
                done

                if [ ${#pacman_official[@]} -gt 0 ]; then
                    echo "📥 Installing official dependencies using pacman..."
                    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
                        pkexec pacman -S --needed --noconfirm "${pacman_official[@]}"
                    else
                        sudo pacman -S --needed --noconfirm "${pacman_official[@]}"
                    fi
                fi

                if [ ${#aur_packages[@]} -gt 0 ]; then
                    echo "⚠️ The following packages are from the AUR repository and are not in the official repos:"
                    echo "   ${aur_packages[*]}"
                    
                    # Try to locate an AUR helper
                    aur_helper=""
                    if command -v yay >/dev/null 2>&1; then
                        aur_helper="yay"
                    elif command -v paru >/dev/null 2>&1; then
                        aur_helper="paru"
                    fi

                    if [ -n "$aur_helper" ]; then
                        echo "🚀 An AUR helper has been detected: $aur_helper. Installing..."
                        # Run AUR helper as the original non-root user if SUDO_USER is defined
                        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                            sudo -u "$SUDO_USER" "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        else
                            "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        fi
                    else
                        echo "❌ No AUR helper (like yay or paru) detected."
                        echo "Please install these packages manually before continuing:"
                        echo "   yay -S ${aur_packages[*]}"
                        exit 1
                    fi
                fi
            elif [ "$pkg_manager" = "apt" ]; then
                if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
                    pkexec /bin/bash -c "apt-get update && apt-get install -y ${packages_to_install[*]}"
                else
                    sudo apt-get update && sudo apt-get install -y "${packages_to_install[@]}"
                fi
            fi
            echo "✅ Successfully installed dependencies."
        else
            echo "✅ There are no packages to install for your platform."
        fi
    else
        echo "❌ Error: Host requirements cannot be met. Going out..."
        exit 1
    fi
fi

# ==============================================================================
# Helper: Auto-Elevate to Root
# Ayudante: Auto-elevación a privilegios de superusuario
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "🔐 This script requires superuser privileges to run."
    echo "Re-ejecutando con pkexec..."
    SCRIPT_PATH="$ISO_DIR/$(basename "${BASH_SOURCE[0]}")"
    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        exec pkexec "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
    else
        exec sudo "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
    fi
fi

# Sanitize root environment (pkexec leaves user's XDG_RUNTIME_DIR which breaks gpg-agent / root sockets)
unset XDG_RUNTIME_DIR
export HOME="/root"

# Build timing: captured after auto-elevation so they survive the re-exec
BUILD_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
BUILD_START_EPOCH=$(date +%s)

SUDO=""

# ==============================================================================
# PHASE 1: Environment Settings and Initialization / FASE 1: Configuración de Entorno
# ==============================================================================

# Import global configs if present / Importar configuración global si existe
if [ -f "../configs/env.sh" ]; then
    source ../configs/env.sh
elif [ -f "configs/env.sh" ]; then
    source configs/env.sh
else
    ARCH="amd64"
    if [ "$DISTRO" = "arch" ]; then
        MIRROR="https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
    else
        MIRROR="http://deb.debian.org/debian"
    fi
fi

if [ "$DISTRO" = "debian" ]; then
    # Override Debian version based on the selected branch
    case "$BRANCH" in
        stable)
            DEBIAN_VERSION="trixie"
            ;;
        forky)
            DEBIAN_VERSION="forky"
            ;;
        rolling)
            DEBIAN_VERSION="testing"
            ;;
    esac
fi

# Paths in the project / Rutas del proyecto
ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ISO_DIR"
BUILD_DIR="$ISO_DIR/build"

# Get the original user who ran the script to find their home and run makepkg
ORIGINAL_USER=""
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ORIGINAL_USER="$SUDO_USER"
elif [ -n "$PKEXEC_UID" ] && [ "$PKEXEC_UID" != "0" ]; then
    ORIGINAL_USER=$(id -un "$PKEXEC_UID" 2>/dev/null || true)
fi

if [ -z "$ORIGINAL_USER" ] || [ "$ORIGINAL_USER" = "root" ]; then
    ORIGINAL_USER=$(stat -c '%U' "$ISO_DIR/.." 2>/dev/null || true)
fi

ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    ORIGINAL_HOME="$HOME"
fi

VARIANT_NAME="$BRANCH-$DISTRO"
if $WITH_NVIDIA; then
    VARIANT_NAME="${VARIANT_NAME}-nvidia"
fi
if $MINIMAL; then
    VARIANT_NAME="${VARIANT_NAME}-minimal"
fi

ROOTFS_BASE="$BUILD_DIR/rootfs-base-${VARIANT_NAME}"
ROOTFS_TARGET="$BUILD_DIR/rootfs-target-${VARIANT_NAME}-${BOOTLOADER}"
ISO_STAGING="$BUILD_DIR/iso-staging-${VARIANT_NAME}-${BOOTLOADER}"

# Pacman cache dir per build variant & bootloader to avoid parallel download/lock collisions
PACMAN_CACHE_DIR="$ORIGINAL_HOME/.cache/pulsaros-pacman-${VARIANT_NAME}-${BOOTLOADER}"
mkdir -p "$PACMAN_CACHE_DIR"
if [ "$EUID" -eq 0 ] && [ -n "$ORIGINAL_USER" ]; then
    chown -R "$ORIGINAL_USER":"$ORIGINAL_USER" "$ORIGINAL_HOME/.cache" 2>/dev/null || true
fi

# CPU & Resource Optimization for Parallel and Safe Builds
TOTAL_CORES=$(nproc 2>/dev/null || echo 4)
if [ -z "$BUILD_PROCESSORS" ]; then
    if [ "$TOTAL_CORES" -ge 8 ]; then
        BUILD_PROCESSORS=$(( TOTAL_CORES / 2 ))
    elif [ "$TOTAL_CORES" -ge 4 ]; then
        BUILD_PROCESSORS=$(( TOTAL_CORES - 1 ))
    else
        BUILD_PROCESSORS=$TOTAL_CORES
    fi
fi

# Run with lower CPU scheduling priority to keep desktop responsive and prevent thermal spikes
renice -n 10 $$ >/dev/null 2>&1 || true
if command -v ionice >/dev/null 2>&1; then
    ionice -c 2 -n 4 -p $$ >/dev/null 2>&1 || true
fi

# Select package list based on distro and minimal flag
if [ "$DISTRO" = "arch" ]; then
    if $MINIMAL; then
        echo "🪶 Minimal mode: using trimmed package list (~2-3GB target)"
        PACKAGE_LIST_FILE="$ISO_DIR/configs/base-arch-minimal.list"
    else
        PACKAGE_LIST_FILE="$ISO_DIR/configs/base-arch.list"
    fi
else
    PACKAGE_LIST_FILE="$ISO_DIR/configs/base.list"
fi

# Adjust paths / Fallback to root repo configuration if local config is missing
# Corregir rutas / Usar configuración del repo raíz como fallback si no existe el de la ISO
if [ ! -f "$PACKAGE_LIST_FILE" ]; then
    if [ "$DISTRO" = "arch" ]; then
        PACKAGE_LIST_FILE="$ISO_DIR/../configs/base-arch.list"
    else
        PACKAGE_LIST_FILE="$ISO_DIR/../configs/base.list"
    fi
fi

# Dynamic detection of chroot binary path
# Detección dinámica de la ruta de chroot en el host
CHROOT_BIN=$(command -v chroot || echo "/usr/sbin/chroot")

## Helper: Unmount directory tree safely
unmount_tree() {
    local target_dir="$1"
    [ -z "$target_dir" ] && return 0
    [ ! -d "$target_dir" ] && return 0
    awk '$2 ~ "^'"$target_dir"'/" || $2 == "'"$target_dir"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
}

# Helper: Safely unmount and remove a directory without touching bind mounts
safe_remove_dir() {
    local target_dir="$1"
    [ -z "$target_dir" ] && return 0
    [ ! -d "$target_dir" ] && return 0
    unmount_tree "$target_dir"
    $SUDO rm -rf "$target_dir" 2>/dev/null || true
}

# Preventative cleanup function to ensure filesystems are unmounted on interruption
# Función de limpieza preventiva para asegurar desmontajes en caso de interrupción
cleanup() {
    echo "🧹 Terminating and freeing chroot-mounted resources for ${VARIANT_NAME}..."

    # Desactivar swap del rootfs target si quedó activo (p.ej. creado por pulsaros-setup-hibernation)
    # Deactivate any swap inside the rootfs target (e.g. created by pulsaros-setup-hibernation)
    if [ -f "$ROOTFS_TARGET/swapfile" ]; then
        $SUDO swapoff "$ROOTFS_TARGET/swapfile" 2>/dev/null || true
    fi

    # Restore original DNS config in target if backup exists
    # Restaurar DNS original en el target si quedó copia
    if [ -f "$ROOTFS_TARGET/etc/resolv.conf.bak" ]; then
        $SUDO mv "$ROOTFS_TARGET/etc/resolv.conf.bak" "$ROOTFS_TARGET/etc/resolv.conf" 2>/dev/null || true
    fi

    unmount_tree "$ROOTFS_TARGET"
    unmount_tree "$ISO_STAGING"

    # Restore host KVM and PTMX node permissions
    if [ -e /dev/kvm ]; then
        $SUDO chmod 666 /dev/kvm 2>/dev/null || true
        $SUDO chown root:kvm /dev/kvm 2>/dev/null || true
    fi
    $SUDO chmod 666 /dev/pts/ptmx 2>/dev/null || true
    if [ ! -c /dev/ptmx ]; then
        $SUDO rm -f /dev/ptmx 2>/dev/null || true
        $SUDO mknod -m 666 /dev/ptmx c 5 2 2>/dev/null || true
    fi
    $SUDO chmod 666 /dev/ptmx 2>/dev/null || true
}

# Preflight: release any leftover mounts from previous interrupted builds for this specific target variant.
preflight_cleanup() {
    echo "🔍 Checking residual mounts for ${VARIANT_NAME}..."
    unmount_tree "$ROOTFS_TARGET"
    unmount_tree "$ISO_STAGING"
    $SUDO chmod 666 /dev/pts/ptmx 2>/dev/null || true
    if [ ! -c /dev/ptmx ]; then
        $SUDO rm -f /dev/ptmx 2>/dev/null || true
        $SUDO mknod -m 666 /dev/ptmx c 5 2 2>/dev/null || true
    fi
    $SUDO chmod 666 /dev/ptmx 2>/dev/null || true
    echo "✅ Residual mnt check completed."
}

# Run a command as the original non-root user without requiring a pty.
# runuser does not need a controlling terminal, so it works when this script
# is re-executed under pkexec (where 'sudo -u' fails to allocate a pty).
# Ejecuta un comando como el usuario original sin requerir una pty.
# runuser no necesita terminal de control, por lo que funciona cuando este
# script se re-ejecuta bajo pkexec (donde 'sudo -u' no puede asignar una pty).
run_as_user() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$ORIGINAL_USER" -- "$@"
    else
        sudo -u "$ORIGINAL_USER" -- "$@"
    fi
}
trap cleanup EXIT INT TERM
preflight_cleanup

# ==============================================================================
# PHASE 2: Build and Maintain Base Cache / FASE 2: Caché Base Virgen
# ==============================================================================

# Auto-cleanup if previous bootstrap was incomplete or corrupted
# Auto-limpieza en caso de bootstrap anterior incompleto o corrupto
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/proc" ] || [ ! -d "$ROOTFS_BASE/boot" ]; }; then
    echo "⚠️ Incomplete or corrupt base cache detected. Cleaning to regenerate..."
    safe_remove_dir "$ROOTFS_BASE"
fi

# Detect if the package list has changed since the cache was created
# Detectar si la lista de paquetes ha cambiado desde que se creó la caché
base_list_changed=false
if [ -d "$ROOTFS_BASE" ] && [ -f "$PACKAGE_LIST_FILE" ]; then
    # Generate the current list of packages to install (line-separated, no comments or empty lines)
    if [ "$DISTRO" = "arch" ]; then
        current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$')
    elif $WITH_NVIDIA; then
        current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$')
    else
        current_list=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64')
    fi
    
    if [ ! -f "$ROOTFS_BASE/etc/pulsaros-base.list" ]; then
        echo "🔄 Pulros-base.list was not found in the cache. Regenerating base..."
        base_list_changed=true
    else
        cached_list=$(cat "$ROOTFS_BASE/etc/pulsaros-base.list")
        if [ "$current_list" != "$cached_list" ]; then
            echo "🔄 A change has been detected in the required package list with respect to the cached base. Regenerating base..."
            base_list_changed=true
        fi
    fi
fi

if $CLEAN_BASE || [ "$base_list_changed" = true ]; then
    echo "🚨 Base cache cleanup requested or package list change detected..."
    safe_remove_dir "$ROOTFS_BASE"
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    mkdir -p "$BUILD_DIR"
    (
        flock -x 200
        if [ ! -d "$ROOTFS_BASE/etc" ]; then
            safe_remove_dir "$ROOTFS_BASE"
            mkdir -p "$ROOTFS_BASE"
            
            if [ "$DISTRO" = "arch" ]; then
                echo "--- 📥 Creating Arch Linux base ---"
                PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ' ')
                
                # Bootstrap Arch Linux using pacstrap
                # Create clean pacman.conf with only official Arch repos to avoid
                # conflicts from third-party repos
                # NOTE: the mirror is pinned to $MIRROR (Arch official by default) so the
                # build does NOT depend on the host OS's repositories -> reproducible
                # builds regardless of the machine that runs build-iso.sh
                CLEAN_PACMAN_CONF="/tmp/pulsaros-pacman-$$.conf"
                cat > "$CLEAN_PACMAN_CONF" <<CLEANEof
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
NoProgressBar
ParallelDownloads = 5

[core]
Server = $MIRROR

[extra]
Server = $MIRROR

[multilib]
Server = $MIRROR
CLEANEof

                mkdir -p "$ROOTFS_BASE"

                # Seed an Arch-pinned pacman keyring BEFORE pacstrap so package signatures
                # validate during the bootstrap.
                mkdir -p "$ROOTFS_BASE/etc/pacman.d"
                if [ -d /etc/pacman.d/gnupg ]; then
                    echo "🔑 Copiando keyring pacman del host al rootfs base..."
                    $SUDO cp -a /etc/pacman.d/gnupg "$ROOTFS_BASE/etc/pacman.d/"
                elif [ -f /usr/share/pacman/keyrings/archlinux.gpg ]; then
                    $SUDO install -d "$ROOTFS_BASE/usr/share/pacman/keyrings"
                    $SUDO cp /usr/share/pacman/keyrings/archlinux.gpg /usr/share/pacman/keyrings/archlinux-trusted \
                        /usr/share/pacman/keyrings/archlinux-revoked "$ROOTFS_BASE/usr/share/pacman/keyrings/"
                    env -u XDG_RUNTIME_DIR HOME="/root" $SUDO pacman-key --gpgdir "$ROOTFS_BASE/etc/pacman.d/gnupg" --init
                    env -u XDG_RUNTIME_DIR HOME="/root" $SUDO pacman-key --gpgdir "$ROOTFS_BASE/etc/pacman.d/gnupg" --populate archlinux
                    $SUDO rm -f "$ROOTFS_BASE"/usr/share/pacman/keyrings/archlinux.gpg \
                        "$ROOTFS_BASE"/usr/share/pacman/keyrings/archlinux-trusted \
                        "$ROOTFS_BASE"/usr/share/pacman/keyrings/archlinux-revoked
                else
                    echo "⚠️  archlinux-keyring not found on host - signatures may fail during bootstrap"
                fi

                # -M: do not copy the host's mirrorlist into the target (reproducibility)
                # -K: initialize and copy keyring from host
                $SUDO pacstrap -K -M -c -C "$CLEAN_PACMAN_CONF" "$ROOTFS_BASE" $PACKAGE_LIST
                rm -f "$CLEAN_PACMAN_CONF"

                # Write the pinned mirrorlist inside the base rootfs as well
                echo "Server = $MIRROR" | $SUDO tee "$ROOTFS_BASE/etc/pacman.d/mirrorlist" > /dev/null

                # Save the actually used package list in the base cache for future diffs
                grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | $SUDO tee "$ROOTFS_BASE/etc/pulsaros-base.list" > /dev/null
                
                echo "✅ Arch base bootstraping completed on $ROOTFS_BASE"
            else
                echo "--- 📥 Creating Clean Debian Base (mmdebstrap) ---"
                
                if $WITH_NVIDIA; then
                    echo "💚 Including proprietary hardware drivers (NVIDIA, Broadcom STA, DKMS, Headers) in the installation..."
                    PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                else
                    echo "💙 Excluding proprietary drivers (NVIDIA, Broadcom STA, DKMS, Headers) from installation..."
                    PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64' | tr '\n' ',' | sed 's/,$//')
                fi
                
                # Add Debian keyring parameter if it exists (required on Ubuntu/Mint hosts)
                KEYRING_PARAM=""
                if [ -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
                    KEYRING_PARAM="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
                    echo "🔑 Usando llavero de Debian: /usr/share/keyrings/debian-archive-keyring.gpg"
                fi
                
                # Execute Debian Bootstrap
                $SUDO /usr/bin/mmdebstrap \
                    --architecture="$ARCH" \
                    --components="main,contrib,non-free,non-free-firmware" \
                    --variant=apt \
                    $KEYRING_PARAM \
                    --include="$PACKAGE_LIST" \
                    "$DEBIAN_VERSION" \
                    "$ROOTFS_BASE" \
                    "$MIRROR"
                    
                # Save the actually used package list in the base cache for future diffs
                if $WITH_NVIDIA; then
                    grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | $SUDO tee "$ROOTFS_BASE/etc/pulsaros-base.list" > /dev/null
                else
                    grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | grep -v -E 'nvidia-driver|nvidia-settings|broadcom-sta-dkms|dkms|linux-headers-amd64' | $SUDO tee "$ROOTFS_BASE/etc/pulsaros-base.list" > /dev/null
                fi
                
                echo "✅ Base Debian Bootstrap completed in: $ROOTFS_BASE"
            fi
        fi
    ) 200>"$BUILD_DIR/.base-${VARIANT_NAME}.lock"
else
    echo "✨ Virgin base detected in cache. Jumping bootstrap."
fi

# ==============================================================================
# PHASE 3: Clone clean base for working target / FASE 3: Clonar base limpia
# ==============================================================================

if [ "$DISTRO" = "arch" ]; then
    echo "--- 🔄 Cloning Arch base in the working directory (target) ---"
else
    echo "--- 🔄 Cloning Debian base in the working directory (target) ---"
fi
cleanup
$SUDO rm -rf "$ROOTFS_TARGET"
mkdir -p "$ROOTFS_TARGET"

# Sync keeping special attributes / Sincronización manteniendo atributos especiales
$SUDO rsync -aHAXx --delete "$ROOTFS_BASE/" "$ROOTFS_TARGET/"
ln -sfn "$ROOTFS_TARGET" "$BUILD_DIR/rootfs-target-${VARIANT_NAME}" 2>/dev/null || true

# ==============================================================================
# PHASE 4: Mount virtual filesystems and network / FASE 4: Montar directorios y red
# ==============================================================================

echo "⚙️ Configuring virtual mounts and DNS..."
$SUDO mount -t proc proc "$ROOTFS_TARGET/proc"
$SUDO mount -t sysfs sys "$ROOTFS_TARGET/sys"
$SUDO mount --bind /dev "$ROOTFS_TARGET/dev"
$SUDO mount --make-rprivate "$ROOTFS_TARGET/dev" 2>/dev/null || true
$SUDO mount --bind /dev/pts "$ROOTFS_TARGET/dev/pts" 2>/dev/null || true
$SUDO mount -t tmpfs tmpfs "$ROOTFS_TARGET/dev/shm" -o mode=1777 2>/dev/null || true
$SUDO chmod 666 /dev/ptmx 2>/dev/null || true
$SUDO chmod 666 /dev/pts/ptmx 2>/dev/null || true

# Bind mount pacman cache dir in home (not root partition) if on Arch
if [ "$DISTRO" = "arch" ]; then
    $SUDO mount --bind "$PACMAN_CACHE_DIR" "$ROOTFS_TARGET/var/cache/pacman/pkg"
    # Purge previously cached Inled-repo packages and obsolete packages (like calamares):
    # an interrupted download or obsolete package leaves stale/broken .pkg.tar.zst in the
    # bind-mounted cache that fails signature checks or reintroduces removed packages.
    for pattern in "pulsaros-*" "tubeos-*" "tube-os-*" "*calamares*" "sayri-*" \
                   "droidtux-*" "macboat-*" "appinstall-*" "seafari-*" \
                   "gnome-macos-remap-wayland-*" "spotlight-gtk-*" \
                   "pulsar-pear-sound-theme-*" "*-debug-*"; do
        $SUDO rm -f "$PACMAN_CACHE_DIR"/$pattern.pkg.tar.zst "$PACMAN_CACHE_DIR"/$pattern.pkg.tar.zst.sig 2>/dev/null || true
    done
fi

# Ensure working DNS in chroot / Asegurar DNS funcional en el chroot
if [ -f "$ROOTFS_TARGET/etc/resolv.conf" ]; then
    $SUDO cp "$ROOTFS_TARGET/etc/resolv.conf" "$ROOTFS_TARGET/etc/resolv.conf.bak"
fi
printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 8.8.4.4\n" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

# English: Create Plymouth theme directory and symlink in advance to satisfy initramfs hooks
# Español: Crear el directorio y el enlace simbólico del tema Plymouth con antelación para satisfacer los hooks de initramfs
theme_dir="$ROOTFS_TARGET/usr/share/plymouth/themes/pulsar-plymouth"
$SUDO mkdir -p "$theme_dir"
$SUDO ln -sf . "$theme_dir/images"

# ==============================================================================
# PHASE 5: Configure repositories and install Pulsar OS / FASE 5: Repositorios
# ==============================================================================

if [ "$DISTRO" = "arch" ]; then
    # ==========================================================================
    # ARCH LINUX PATH
    # ==========================================================================
    echo "--- 🐧 Configuring Arch Linux (Inled) repositories ---"

    # Copy the Inled keyring to chroot
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg"

    # Write a complete default pacman.conf with [inled] repository at top priority
    $SUDO tee "$ROOTFS_TARGET/etc/pacman.conf" > /dev/null <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Optional TrustAll
LocalFileSigLevel = Optional
#CheckSpace
NoProgressBar
# Downloads are serial (one at a time) to avoid GitHub release rate-limiting that
# causes intermittent 404s when pacman fetches the [inled] repo (redirects to GitHub).
ParallelDownloads = 1

[inled]
SigLevel = Optional TrustAll
Server = https://apt.inled.es/arch/

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF

    # Disable CheckSpace: inside chroot, pacman reads host's /proc/self/mountinfo
    # and can't find chroot root as a mountpoint, causing false 'not enough space' errors.
    $SUDO sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' "$ROOTFS_TARGET/etc/pacman.conf"

    # Bootstrap packages into target
    if [ "$BOOTLOADER" = "grub" ]; then
        BOOTLOADER_PKGS="grub efibootmgr os-prober"
    else
        BOOTLOADER_PKGS="refind efibootmgr grub os-prober"
    fi

    if $USE_LOCAL_PKGS; then
        echo "--- 🛠️ LOCAL DEVELOPMENT MODE: Installing local Arch packages ---"
        pkg_dir_source="$ISO_DIR/../PKG/arch"
        if [ ! -d "$pkg_dir_source" ]; then
            pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG/arch"
        fi

        if $SKIP_PKG_BUILD; then
            echo "⚡ [SKIP-ALL] Reusing already compiled packages in build/packages (skipping compilation)..."
        elif [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
            chmod +x "$pkg_dir_source/package-and-deploy.sh" 2>/dev/null || true
            pkg_cmd="./package-and-deploy.sh all"
            if $INCREMENTAL_PKG_BUILD; then
                echo "⚡ [INCREMENTAL] Checking and rebuilding only modified packages..."
                pkg_cmd="./package-and-deploy.sh all --incremental"
            else
                echo "🔨 Compilando todos los paquetes locales de forma fresca..."
            fi
            # Run as the original non-root user since makepkg cannot run as root
            if [ -n "$ORIGINAL_USER" ] && [ "$ORIGINAL_USER" != "root" ]; then
                run_as_user bash -c "cd '$pkg_dir_source' && $pkg_cmd"
            else
                (cd "$pkg_dir_source" && eval "$pkg_cmd")
            fi
        else
            echo "⚠️ Warning: Packaging script not found in $pkg_dir_source/package-and-deploy.sh. An attempt will be made to use pre-existing packages."
        fi

        LOCAL_PKGS_DIR=""
        POSSIBLE_DIRS=(
            "$ISO_DIR/../PKG/arch/build/packages"
            "$ISO_DIR/../PKG/build/packages"
            "/home/jaime/Documentos/pulsarbase/PKG/arch/build/packages"
        )

        for dir in "${POSSIBLE_DIRS[@]}"; do
            if [ -d "$dir" ] && [ -n "$(ls "$dir"/*.pkg.tar.zst 2>/dev/null)" ]; then
                LOCAL_PKGS_DIR="$dir"
                break
            fi
        done

        if [ -z "$LOCAL_PKGS_DIR" ]; then
            echo "❌ Error: No local Arch packages found in any of the search paths:"
            for dir in "${POSSIBLE_DIRS[@]}"; do echo "   - $dir"; done
            echo "First run the packager in the PKG/arch/folder."
            exit 1
        fi

        # Deduplicate local packages keeping only the newest version of each
        # package. pacman -U rejects two versions of the same package with
        # "duplicate target", and the package build directory accumulates old
        # builds over time.
        echo "🧹 Removing old versions and orphan packages from local packages..."
        for pkg_file in $(ls -rv "$LOCAL_PKGS_DIR"/*.pkg.tar.zst 2>/dev/null); do
            pkg_name=$(LC_ALL=C pacman -Qip "$pkg_file" 2>/dev/null | awk -F': ' '/^Name/{print $2; exit}')
            [ -z "$pkg_name" ] && continue
            if [[ "$pkg_name" == *calamares* ]] || [[ "$pkg_name" == *-debug* ]]; then
                echo "   Eliminando paquete no deseado: $(basename "$pkg_file")"
                rm -f "$pkg_file"
                continue
            fi
            if echo "$seen_pkg_names" | grep -qx "$pkg_name"; then
                echo "   Eliminando versión anterior de $pkg_name: $(basename "$pkg_file")"
                rm -f "$pkg_file"
            else
                seen_pkg_names="$seen_pkg_names
$pkg_name"
            fi
        done
        unset seen_pkg_names

        # cloudflare-warp-bin is bundled in the (minimal) ISO so the recovery/installer can
        # offer the user a VPN to reach the Inled repo in regions where Cloudflare is censored.
        # localsend-bin is an extra package offered post-install. Both must be compiled from AUR
        # since they are not present in the official repos or the Inled repo.
        AUR_DEPS=("pamtester" "xremap-gnome-bin" "autokey-gtk" "winboat-bin" "cloudflare-warp-bin" "localsend-bin")
        aur_helper=""
        if command -v yay >/dev/null 2>&1; then
            aur_helper="yay"
        elif command -v paru >/dev/null 2>&1; then
            aur_helper="paru"
        fi

        if [ -n "$aur_helper" ]; then
            for dep in "${AUR_DEPS[@]}"; do
                # Check if package is already built/present in LOCAL_PKGS_DIR
                if ls "$LOCAL_PKGS_DIR"/$dep-*.pkg.tar.zst >/dev/null 2>&1; then
                    echo "✅ AUR dependency already compiled: $dep"
                    continue
                fi
                
                echo "🔨 Compiling AUR dependency: $dep..."
                BUILD_TEMP_DIR="/tmp/pulsaros-aur-$dep-$$"
                $SUDO rm -rf "$BUILD_TEMP_DIR"
                mkdir -p "$BUILD_TEMP_DIR"
                $SUDO chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$BUILD_TEMP_DIR"
                
                # Resolve package base name for split packages
                pkg_base="$dep"
                if [ "$dep" = "autokey-gtk" ]; then
                    pkg_base="autokey"
                fi

                # Download PKGBUILD using git clone directly for reliability and speed
                run_as_user bash -c "cd '$BUILD_TEMP_DIR' && git clone https://aur.archlinux.org/${pkg_base}.git"
                
                # Dynamically locate the directory containing the PKGBUILD
                dep_dir=$(find "$BUILD_TEMP_DIR" -maxdepth 2 -name "PKGBUILD" -exec dirname {} \; | head -n 1)

                if [ -n "$dep_dir" ]; then
                    # If we are building autokey, strip autokey-qt to avoid unresolvable Qt5/QScintilla dependencies
                    if [ "$pkg_base" = "autokey" ]; then
                        echo "⚙️ Quitando autokey-qt del PKGBUILD para evitar fallos de dependencias..."
                        sed -i "s/'autokey-qt'//g" "$dep_dir/PKGBUILD"
                        sed -i 's/"autokey-qt"//g' "$dep_dir/PKGBUILD"
                        sed -i 's/ autokey-qt//g' "$dep_dir/PKGBUILD"
                        sed -i "s/''//g" "$dep_dir/PKGBUILD"
                        sed -i 's/""//g' "$dep_dir/PKGBUILD"
                    fi

                    # Build package and save to LOCAL_PKGS_DIR
                    # We run as ORIGINAL_USER since makepkg cannot run as root.
                    # Use -cfd to build without checking or installing dependencies on the host system.
                    # Local AUR dependencies are installed inside the target chroot, never on the host.
                    if ! run_as_user bash -c "cd '$dep_dir' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -cfd --noconfirm --nosign"; then
                        echo "❌ Error: Could not compile AUR dependency: $dep"
                        exit 1
                    fi
                    echo "✅ AUR dependency $dep compiled successfully."
                else
                    echo "❌ Error: Could not get the PKGBUILD for $dep."
                    exit 1
                fi
                $SUDO rm -rf "$BUILD_TEMP_DIR"
            done
        fi

        echo "📂 Using local packages from: $LOCAL_PKGS_DIR"

        $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
        $SUDO cp "$LOCAL_PKGS_DIR"/*.pkg.tar.zst "$ROOTFS_TARGET/tmp/packages/"
        
        # Clean up packages that are not needed or cause dependency issues inside the chroot
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/autokey-qt-*.pkg.tar.zst
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/*-debug-*.pkg.tar.zst
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/*calamares*
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/gnome-keybindings-*
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/spotlight-gtk-*.pkg.tar.zst
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/tubeos-*.pkg.tar.zst
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/tube-os-*.pkg.tar.zst
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/dockermigrate-*.pkg.tar.zst

        if [ "$BOOTLOADER" = "grub" ]; then
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-refind-*.pkg.tar.zst
        else
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-grub-*.pkg.tar.zst
        fi

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

            # Verify pacman is available in chroot
            if ! command -v pacman >/dev/null 2>&1; then
                echo '❌ ERROR: pacman not found in chroot. ROOTFS may be incomplete.'
                echo '   Delete build/rootfs-base-* and rebuild.'
                exit 1
            fi

            # Init pacman keyring
            mkdir -p /etc/pacman.d/gnupg
            chmod 755 /etc/pacman.d/gnupg

            # Write mirrorlist
            echo 'Server = $MIRROR' > /etc/pacman.d/mirrorlist

            # Init keyring, import Inled repo key first, then sync and populate
            /usr/bin/pacman-key --init

            # Import and sign Inled repo key from bundled file (before syncing Inled repo)
            if [ -f /usr/share/keyrings/inled-archive-keyring.gpg ]; then
                /usr/bin/pacman-key --add /usr/share/keyrings/inled-archive-keyring.gpg
                /usr/bin/pacman-key --lsign-key 89F828A9675B63CD0077CE9965AA57CF36E2018F 2>/dev/null || true
            fi
            chmod 755 /etc/pacman.d/gnupg
            chmod 644 /etc/pacman.d/gnupg/pubring.gpg /etc/pacman.d/gnupg/trustdb.gpg /etc/pacman.d/gnupg/tofu.db /etc/pacman.d/gnupg/gpg.conf 2>/dev/null || true

            /usr/bin/pacman -Syy --noconfirm
            /usr/bin/pacman -S --noconfirm archlinux-keyring qt6-multimedia-ffmpeg
            /usr/bin/pacman-key --populate archlinux

            # Perform a full system upgrade of the base chroot first to prevent rolling-release dependency conflicts
            pacman -Syu --noconfirm --overwrite '*'

            # Arch now ships libnautilus-extension as a separate package, but our
            # bundled nautilus build provides/conflicts with it; remove upstream copy first
            if pacman -Q libnautilus-extension >/dev/null 2>&1; then
                pacman -Rdd --noconfirm libnautilus-extension || true
            fi

            # Install local packages (using -U) and pull dependencies
            pacman -U --noconfirm --overwrite '*' /tmp/packages/*.pkg.tar.zst

            # Pin our custom nautilus so subsequent pacman runs don't replace it with upstream
            if ! grep -q '^IgnorePkg' /etc/pacman.conf; then
                sed -i '/^Architecture = auto$/a IgnorePkg = nautilus' /etc/pacman.conf
            fi

            # Install remaining dependencies and packages.
            # droidtux/macboat/appinstall/seafari come from the [inled] repo via pacman.
            pacman -S --needed --noconfirm --overwrite '*' \
                $BOOTLOADER_PKGS \
                droidtux \
                macboat \
                appinstall \
                seafari \
                qt6-multimedia \
                qt6-multimedia-gstreamer
        "
        $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        if ! grep -q '\[inled\]' "$ROOTFS_TARGET/etc/pacman.conf"; then
            $SUDO sed -i '/\[core\]/i \[inled\]\nSigLevel = Optional TrustAll\nServer = https://apt.inled.es/arch/\n' "$ROOTFS_TARGET/etc/pacman.conf"
        fi
        echo "✅ Successfully installed local Arch packages."
    else
        echo "---🌐 PRODUCTION MODE: Installing packages from Arch repository (Inled) ---"

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

            # Verify pacman is available in chroot
            if ! command -v pacman >/dev/null 2>&1; then
                echo '❌ ERROR: pacman not found in chroot. ROOTFS may be incomplete.'
                echo '   Delete build/rootfs-base-* and rebuild.'
                exit 1
            fi

            # Init pacman keyring
            mkdir -p /etc/pacman.d/gnupg
            chmod 755 /etc/pacman.d/gnupg

            # Write mirrorlist
            echo 'Server = $MIRROR' > /etc/pacman.d/mirrorlist

            # Init keyring, import Inled key, then sync and populate
            /usr/bin/pacman-key --init

            # Import and sign Inled repo key from bundled file (before syncing Inled repo)
            if [ -f /usr/share/keyrings/inled-archive-keyring.gpg ]; then
                /usr/bin/pacman-key --add /usr/share/keyrings/inled-archive-keyring.gpg
                /usr/bin/pacman-key --lsign-key 89F828A9675B63CD0077CE9965AA57CF36E2018F 2>/dev/null || true
            fi
            chmod 755 /etc/pacman.d/gnupg
            chmod 644 /etc/pacman.d/gnupg/pubring.gpg /etc/pacman.d/gnupg/trustdb.gpg /etc/pacman.d/gnupg/tofu.db /etc/pacman.d/gnupg/gpg.conf 2>/dev/null || true

            /usr/bin/pacman -Syy --noconfirm
            /usr/bin/pacman -S --noconfirm archlinux-keyring
            /usr/bin/pacman-key --populate archlinux

            # Arch now ships libnautilus-extension as a separate package, but our
            # bundled nautilus build provides/conflicts with it; remove upstream copy first
            if /usr/bin/pacman -Q libnautilus-extension >/dev/null 2>&1; then
                /usr/bin/pacman -Rdd --noconfirm libnautilus-extension || true
            fi

            # Install Pulsar OS packages and bootloader
            # droidtux/macboat/appinstall/seafari come from the [inled] repo via pacman.
            /usr/bin/pacman -Syu --noconfirm --overwrite '*' \
                $BOOTLOADER_PKGS \
                gnome-control-center \
                nautilus \
                gnome-keybindings \
                pulsaros-branding \
                pulsaros-theme \
                pulsaros-gnome \
                sayri \
                pulsaros-global-menu \
                pulsaros-spotlight-launcher \
                pulsaros-sddm \
                pulsaros-plymouth \
                pulsaros-$BOOTLOADER \
                pulsaros-essential \
                pulsaros-welcome \
                pulsaros-recovery \
                pulsaros-live-wallpaper \
                pulsaros-bootsound \
                pulsaros-hibernate \
                pulsar-pear-sound-theme \
                pulsaros-boot-icons \
                gnome-macos-remap-wayland \
                droidtux \
                macboat \
                appinstall \
                seafari \
                qt6-multimedia \
                qt6-multimedia-gstreamer \
                winboat-bin
        "
        echo "✅ Arch packages installed from the Inled repository."
    fi

    # The archlinux:latest Docker image ships a /etc/pacman.conf with
    # 'NoExtract = usr/share/i18n/*' (only en_* locales, C/POSIX and two
    # charmaps are whitelisted), so the pacstrap base never writes
    # /usr/share/i18n/SUPPORTED nor most locale sources. The OOTB assistant
    # reads /usr/share/i18n/SUPPORTED and aborts without it. Restore the full
    # i18n subtree from the glibc package (the chroot's pacman.conf is clean,
    # so the download is not affected by the image's NoExtract).
    echo "🔤 Restoring full glibc local sources..."
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        /usr/bin/pacman -Sw --noconfirm glibc >/dev/null 2>&1
        glibc_pkg=\$(ls -1 /var/cache/pacman/pkg/glibc-*.pkg.tar.zst 2>/dev/null | tail -n 1)
        if [ -z \"\$glibc_pkg\" ]; then
            echo '❌ No se pudo descargar glibc para restaurar i18n' >&2
            exit 1
        fi
        tar --zstd -xf \"\$glibc_pkg\" -C / usr/share/i18n
        rm -f \"\$glibc_pkg\" \"\$glibc_pkg.sig\"
        echo '✅ Locales de glibc restaurados.'
    "
else
    # Ensure solid DNS in chroot
    $SUDO rm -f "$ROOTFS_TARGET/etc/resolv.conf"
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

    echo "--- 🌐 Configuring APT repositories (Debian Contrib/Backports and Inled) ---"
    $SUDO sed -i "s/$DEBIAN_VERSION main/$DEBIAN_VERSION main contrib non-free non-free-firmware/g" "$ROOTFS_TARGET/etc/apt/sources.list"
    if [ "$DEBIAN_VERSION" != "trixie" ] && [ "$DEBIAN_VERSION" != "forky" ] && [ "$DEBIAN_VERSION" != "sid" ]; then
        if ! grep -q "${DEBIAN_VERSION}-backports" "$ROOTFS_TARGET/etc/apt/sources.list"; then
            echo "deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware" | $SUDO tee -a "$ROOTFS_TARGET/etc/apt/sources.list" > /dev/null
        fi
    fi

    # Copy the bundled Inled APT GPG keyring directly to the chroot target
    echo "🔑 Copying the pre-packaged Inled GPG keychain..."
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg"

    echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es $BRANCH main" | \
        $SUDO tee "$ROOTFS_TARGET/etc/apt/sources.list.d/inled.list" > /dev/null

    $SUDO tee "$ROOTFS_TARGET/etc/apt/preferences.d/99inled" > /dev/null <<'EOF'
Package: *
Pin: origin "apt.inled.es"
Pin-Priority: 1001
EOF

    # Create temporary dpkg-diverts to intercept DroidTux's and AppInstall's keyring setup
    echo "⚙️ Setting up temporary dpkg bypasses for DroidTux and AppInstall..."
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        dpkg-divert --add --rename --divert /usr/bin/curl.real /usr/bin/curl
        dpkg-divert --add --rename --divert /usr/bin/wget.real /usr/bin/wget
        dpkg-divert --add --rename --divert /usr/bin/gpg.real /usr/bin/gpg
    "

    $SUDO tee "$ROOTFS_TARGET/usr/bin/curl" > /dev/null << 'EOF'
#!/bin/bash
if [[ "$*" == *"apt.inled.es/archive.key"* ]]; then
    echo "dummy-key"
    exit 0
fi
exec /usr/bin/curl.real "$@"
EOF
    $SUDO chmod +x "$ROOTFS_TARGET/usr/bin/curl"

    $SUDO tee "$ROOTFS_TARGET/usr/bin/wget" > /dev/null << 'EOF'
#!/bin/bash
if [[ "$*" == *"apt.inled.es/archive.key"* ]]; then
    echo "dummy-key"
    exit 0
fi
exec /usr/bin/wget.real "$@"
EOF
    $SUDO chmod +x "$ROOTFS_TARGET/usr/bin/wget"

    $SUDO tee "$ROOTFS_TARGET/usr/bin/gpg" > /dev/null << 'EOF'
#!/bin/bash
if [[ "$*" == *"--dearmor"* ]] && [[ "$*" == *"/usr/share/keyrings/inled-archive-keyring.gpg"* ]]; then
    exit 0
fi
exec /usr/bin/gpg.real --yes --batch "$@"
EOF
    $SUDO chmod +x "$ROOTFS_TARGET/usr/bin/gpg"

    if $USE_LOCAL_PKGS; then
        echo "--- 🛠️ MODO DESARROLLO LOCAL: Instalando paquetes deb locales ---"
        pkg_dir_source="$ISO_DIR/../PKG"
        if [ ! -d "$pkg_dir_source" ]; then
            pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG"
        fi

        if $SKIP_PKG_BUILD; then
            echo "⚡ [SKIP-ALL] Reutilizando paquetes .deb ya compilados en build/packages (omitiendo compilación)..."
        elif [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
            chmod +x "$pkg_dir_source/package-and-deploy.sh" 2>/dev/null || true
            pkg_cmd="./package-and-deploy.sh all --branch $BRANCH"
            if $INCREMENTAL_PKG_BUILD; then
                echo "⚡ [INCREMENTAL] Comprobando y recompilando únicamente paquetes .deb modificados para $BRANCH..."
                pkg_cmd="./package-and-deploy.sh all --incremental --branch $BRANCH"
            else
                echo "🔨 Compilando todos los paquetes locales de forma fresca para la rama $BRANCH..."
            fi
            (cd "$pkg_dir_source" && eval "$pkg_cmd")
        else
            echo "⚠️ Warning: Packaging script not found in $pkg_dir_source/package-and-deploy.sh. An attempt will be made to use pre-existing debs."
        fi

        LOCAL_DEBS_DIR=""
        POSSIBLE_DIRS=(
            "$ISO_DIR/../PKG/build/packages"
            "$ISO_DIR/../build/packages"
            "$ISO_DIR/build/packages"
            "/home/jaime/Documentos/pulsarbase/PKG/build/packages"
        )

        for dir in "${POSSIBLE_DIRS[@]}"; do
            if [ -d "$dir" ] && [ -n "$(ls "$dir"/*.deb 2>/dev/null)" ]; then
                LOCAL_DEBS_DIR="$dir"
                break
            fi
        done

        if [ -z "$LOCAL_DEBS_DIR" ]; then
            echo "❌Error: No local .deb packages found in any of the search paths:"
            for dir in "${POSSIBLE_DIRS[@]}"; do echo "   - $dir"; done
            echo "Ejecuta primero el empaquetador en la carpeta PKG/."
            exit 1
        fi

        echo "📂 Using local packages from: $LOCAL_DEBS_DIR"
        $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
        $SUDO cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/*calamares*
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/*-debug*
        if [ "$BOOTLOADER" = "grub" ]; then
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-refind_*.deb
        else
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-grub_*.deb
        fi

        if [ "$BOOTLOADER" = "grub" ]; then
            BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin efibootmgr os-prober"
        else
            BOOTLOADER_PKGS="refind efibootmgr grub-pc grub-efi-amd64-bin os-prober"
        fi

        $SUDO tee "$ROOTFS_TARGET/etc/apt/preferences.d/local-pulsar" > /dev/null <<EOF
Package: pulsaros-* gnome-macos-remap-wayland
Pin: release *
Pin-Priority: -1
EOF

        # Ensure working DNS right before entering chroot
        $SUDO rm -f "$ROOTFS_TARGET/etc/resolv.conf"
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export DEBIAN_FRONTEND=noninteractive
            export PULSAR_BUILD_CHROOT=1
            echo 'refind refind/install_to_esp boolean false' | debconf-set-selections
            echo 'DPkg::options { \"--force-overwrite\"; };' > /etc/apt/apt.conf.d/99force-overwrite
            apt-get update || true
            apt-get install -y scrcpy 2>/dev/null || apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy 2>/dev/null || true
            yes | apt-get install -y --no-install-recommends \$BOOTLOADER_PKGS
            yes | apt-get install -y \
                /tmp/packages/*.deb \
                droidtux \
                macboat \
                appinstall \
                seafari || yes | apt-get install -y /tmp/packages/*.deb
            rm -f /etc/apt/apt.conf.d/99force-overwrite
            apt-get clean
        "
        $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        $SUDO rm -f "$ROOTFS_TARGET/etc/apt/preferences.d/local-pulsar"
        echo "✅ Local and cross-installed packages successfully."
    else
        echo "---🌐 PRODUCTION MODE: Installing packages from APT repository ---"
        if [ "$BOOTLOADER" = "grub" ]; then
            BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin efibootmgr os-prober"
        else
            BOOTLOADER_PKGS="refind efibootmgr grub-pc grub-efi-amd64-bin os-prober"
        fi

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export DEBIAN_FRONTEND=noninteractive
            export PULSAR_BUILD_CHROOT=1
            echo 'refind refind/install_to_esp boolean false' | debconf-set-selections
            echo 'DPkg::options { "--force-overwrite"; };' > /etc/apt/apt.conf.d/99force-overwrite
            apt-get update
            yes | apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
            yes | apt-get install -y --no-install-recommends \
                $BOOTLOADER_PKGS \
                pulsaros-branding \
                pulsaros-theme \
                pulsaros-gnome \
                sayri \
                nautilus \
                pulsaros-control-center \
                pulsaros-global-menu \
                pulsaros-spotlight-launcher \
                pulsaros-sddm \
                pulsaros-plymouth \
                pulsaros-$BOOTLOADER \
                pulsaros-essential \
                pulsaros-welcome \
                pulsaros-recovery \
                pulsaros-bootsound \
                pulsaros-hibernate \
                pulsar-pear-sound-theme \
                pulsaros-boot-icons \
                gnome-macos-remap-wayland \
                droidtux \
                macboat \
                appinstall \
                seafari
            rm -f /etc/apt/apt.conf.d/99force-overwrite
            apt-get clean
        "
    fi

    # Clean up temporary DroidTux and AppInstall mocks and restore dpkg-diverts
    echo "🧹 Cleaning DroidTux and AppInstall dpkg mocks and bypasses..."
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/curl"
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/wget"
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/gpg"

    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        dpkg-divert --remove --rename /usr/bin/curl
        dpkg-divert --remove --rename /usr/bin/wget
        dpkg-divert --remove --rename /usr/bin/gpg
    "
fi

# ==============================================================================
# Install pre-compiled Tauri binary for pulsaros-welcome
# Instalar el binario Tauri pre-compilado de pulsaros-welcome
#
# The pulsaros-welcome package installed from the repo may only contain the
# Python+WebKitGTK fallback. The Tauri binary (compiled on the build host with
# `npx tauri build`) must be installed separately at /usr/lib/pulsaros-welcome/
# so the wrapper at /usr/bin/pulsaros-welcome picks it up. The binary is
# architecture-specific: it must be compiled on the same distro as the target
# rootfs (Arch binary for Arch ISOs, Debian binary for Debian ISOs).
# ==============================================================================
echo "🦀 Installing pre-compiled pulsaros-welcome Tauri binary..."
WELCOME_PKG_SRC="$ISO_DIR/../PKG/pulsaros-welcome"
WELCOME_TAURI_BIN="$WELCOME_PKG_SRC/usr/share/pulsaros-welcome/src-tauri/target/release/pulsaros-welcome"

if [ -f "$WELCOME_TAURI_BIN" ] && [ -x "$WELCOME_TAURI_BIN" ]; then
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/lib/pulsaros-welcome"
    $SUDO cp -f "$WELCOME_TAURI_BIN" "$ROOTFS_TARGET/usr/lib/pulsaros-welcome/pulsaros-welcome"
    $SUDO chmod 755 "$ROOTFS_TARGET/usr/lib/pulsaros-welcome/pulsaros-welcome"
    # Also update the wrapper script to the new version that checks /usr/lib first
    $SUDO cp -f "$WELCOME_PKG_SRC/usr/bin/pulsaros-welcome" "$ROOTFS_TARGET/usr/bin/pulsaros-welcome"
    $SUDO chmod 755 "$ROOTFS_TARGET/usr/bin/pulsaros-welcome"
    # Also update dist/ with the freshly built frontend assets
    if [ -d "$WELCOME_PKG_SRC/usr/share/pulsaros-welcome/dist" ]; then
        $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/pulsaros-welcome"
        $SUDO cp -rf "$WELCOME_PKG_SRC/usr/share/pulsaros-welcome/dist" \
                     "$ROOTFS_TARGET/usr/share/pulsaros-welcome/"
    fi
    echo "✅ pulsaros-welcome Tauri binary installed at /usr/lib/pulsaros-welcome/pulsaros-welcome"
else
    echo "⚠️  pulsaros-welcome Tauri binary not found at $WELCOME_TAURI_BIN"
    echo "   Run 'npx tauri build' inside PKG/pulsaros-welcome/usr/share/pulsaros-welcome"
    echo "   to compile it before building the ISO. Python fallback will be used."
fi

# ==============================================================================
# Cloudflare WARP for the Debian edition (installed the official way)
#
# The official Debian instructions add Cloudflare's own APT repo and install the
# cloudflare-warp package from it. It is bundled in the ISO so the recovery and
# installer can offer the user a VPN to reach the Inled repo in regions where
# Cloudflare is censored. (On Arch we bundle cloudflare-warp-bin from the AUR.)
# ==============================================================================
if [ "$DISTRO" = "debian" ]; then
    echo "🌐 Installing Cloudflare WARP (official Debian repo) in the target..."
    # Add Cloudflare's signed-by APT source from the host to avoid nested quoting.
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO bash -c "curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output '$ROOTFS_TARGET/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg'" 2>/dev/null || true
    $SUDO mkdir -p "$ROOTFS_TARGET/etc/apt/sources.list.d"
    if [ -f "$ROOTFS_TARGET/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg" ]; then
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | $SUDO tee "$ROOTFS_TARGET/etc/apt/sources.list.d/cloudflare-warp.list" > /dev/null
    else
        echo "⚠️  Cloudflare WARP keyring not downloaded, skipping repo setup."
    fi
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update 2>/dev/null && \
        apt-get install -y --no-install-recommends cloudflare-warp 2>/dev/null && \
        systemctl enable warp-svc 2>/dev/null || \
        echo '⚠️  Cloudflare WARP not available, skipping (ISO will still work without VPN)'
        apt-get clean 2>/dev/null || true
    "
fi

#

# ==============================================================================
# PHASE 5.5: Configure System Apps (Flatpak and External Winboat)
# FASE 5.5: Configuración de Aplicaciones del Sistema (Flatpak y Winboat)
# ==============================================================================

# Configure spotlight icon / Configurar el icono de spotlight a 'view-app-grid'
echo "⚙️ Customizing Spotlight launcher..."
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    set -e
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    if [ -f /usr/share/applications/pulsaros-spotlight.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/pulsaros-spotlight.desktop
    elif [ -f /usr/share/applications/spotlight-python.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-python.desktop
    elif [ -f /usr/share/applications/spotlight-gtk.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-gtk.desktop
    fi
"

if [ "$DISTRO" = "debian" ]; then
    # Download external winboat dependencies on host and copy to chroot
    echo "📥 Downloading external dependencies (Winboat) on the host..."
    WINBOAT_TMP="$BUILD_DIR/winboat-${VARIANT_NAME}-${BOOTLOADER}-$$.deb"
    wget -q --timeout=15 --tries=3 -O "$WINBOAT_TMP" https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-amd64.deb
    $SUDO cp "$WINBOAT_TMP" "$ROOTFS_TARGET/tmp/winboat.deb"
    rm -f "$WINBOAT_TMP"

    echo "📥 Installing Winboat..."
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        apt-get install -y /tmp/winboat.deb
        rm -f /tmp/winboat.deb
    "
elif [ "$DISTRO" = "arch" ]; then
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        if ! command -v winboat >/dev/null 2>&1 && [ ! -f /opt/winboat/winboat ]; then
            echo '📥 Installing Winboat on Arch (fallback)...'
            /usr/bin/pacman -S --noconfirm winboat-bin 2>/dev/null || {
                mkdir -p /tmp/winboat-install
                cd /tmp/winboat-install
                curl -sL -o winboat.deb https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-amd64.deb
                bsdtar -xf winboat.deb data.tar.xz
                bsdtar -xf data.tar.xz -C /
                cd /
                rm -rf /tmp/winboat-install
            }
        fi
    "
fi

# Configurar Flathub en el sistema e instalar Flatpaks esenciales (con caché persistente local)
FLATPAK_CACHE_DIR="$BUILD_DIR/flatpak-cache"
if [ -d "$ROOTFS_TARGET/var/lib/flatpak/app/io.github.jeffshee.Hidamari" ]; then
    echo "✨ Hidamari (Flatpak) ya está presente en el rootfs. Omitiendo descarga."
else
    echo "📦 Configurando repositorio Flathub e instalando Flatpaks..."
    if [ -d "$FLATPAK_CACHE_DIR" ] && [ -d "$FLATPAK_CACHE_DIR/app/io.github.jeffshee.Hidamari" ]; then
        echo "⚡ Restaurando Flatpaks (Hidamari y runtimes) desde la caché local ($FLATPAK_CACHE_DIR)..."
        $SUDO mkdir -p "$ROOTFS_TARGET/var/lib/flatpak"
        $SUDO cp -a "$FLATPAK_CACHE_DIR"/* "$ROOTFS_TARGET/var/lib/flatpak/" 2>/dev/null || true
    fi

    if [ ! -d "$ROOTFS_TARGET/var/lib/flatpak/app/io.github.jeffshee.Hidamari" ]; then
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
            flatpak install --system -y --noninteractive flathub io.github.jeffshee.Hidamari || true
        "
        if [ -d "$ROOTFS_TARGET/var/lib/flatpak/app/io.github.jeffshee.Hidamari" ]; then
            echo "💾 Guardando Flatpaks en la caché local persistente ($FLATPAK_CACHE_DIR)..."
            $SUDO mkdir -p "$FLATPAK_CACHE_DIR"
            $SUDO cp -a "$ROOTFS_TARGET/var/lib/flatpak"/* "$FLATPAK_CACHE_DIR/" 2>/dev/null || true
        fi
    else
        echo "✅ Hidamari y runtimes restaurados instantáneamente desde la caché local (0s de descarga)."
    fi
fi

# Asegurar identidad visual y logo oficial de Pulsar OS en GNOME Settings
echo "🎨 Aplicando identidad visual y logo de Pulsar OS..."
    _iso_ver="${PULSAR_VERSION:-rolling}"
    _iso_base="Pulsar OS Bitten Fruit ${DISTRO^} Based"
    _iso_pretty="$_iso_base"
    if [ -n "$PULSAR_VERSION" ] && [ "$PULSAR_VERSION" != "rolling" ]; then
        _iso_pretty="$_iso_base ($PULSAR_VERSION)"
    fi
    _build_id="$(date +%Y%m%d%H%M)"

    cat <<EOF > "$ROOTFS_TARGET/etc/os-release"
NAME="Pulsar OS"
PRETTY_NAME="${_iso_pretty}"
VERSION_ID="${_iso_ver}"
VERSION="${_iso_ver}"
BUILD_ID="${_build_id}"
IMAGE_VERSION="${_iso_ver}"
ID=pulsaros
ID_LIKE=arch
HOME_URL="https://os.inled.es"
DOCUMENTATION_URL="https://os.inled.es/help/"
SUPPORT_URL="https://link.inled.es/discord"
BUG_REPORT_URL="https://github.com/Inled-Pulsar-OS"
PRIVACY_POLICY_URL="https://inled.es"
LOGO=pulsar-logo
ANSI_COLOR="38;2;135;206;235"
EOF
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/lib"
    $SUDO cp -f "$ROOTFS_TARGET/etc/os-release" "$ROOTFS_TARGET/usr/lib/os-release"
    
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    
    # Reemplazar cualquier logo residual de Manjaro/Arch con el de Pulsar OS
    if [ -f /usr/share/pixmaps/pulsar-logo.png ]; then
        for alias in distributor-logo archlinux-logo manjarolinux-logo manjaro-logo; do
            cp -f /usr/share/pixmaps/pulsar-logo.png /usr/share/pixmaps/\$alias.png 2>/dev/null || true
        done
    fi
    if [ -f /usr/share/icons/manjaro/manjarolinux-text-dark-rounded.svg ]; then
        cp -f /usr/share/icons/manjaro/manjarolinux-text-dark-rounded.svg /usr/share/icons/manjaro/manjarolinux-text-rounded.svg 2>/dev/null || true
    fi
    
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
"

# English: Configure static autologin for SDDM live user inside the rootfs (using GNOME Wayland)
# Español: Configurar autologin estático para el usuario live de SDDM en el rootfs (usando GNOME Wayland)
echo "⚙️ Configuring static autologin for the live session (Wayland)..."
$SUDO mkdir -p "$ROOTFS_TARGET/etc/sddm.conf.d"
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf" > /dev/null
[Autologin]
User=live
Session=gnome
EOF
$SUDO chmod 644 "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf"

# Force Plymouth to not use SimpleDRM in the configuration file to prevent early boot graphics freezes
if [ -f "$ROOTFS_TARGET/etc/plymouth/plymouthd.conf" ]; then
    echo "⚙️ Forzando UseSimpledrm=false en /etc/plymouth/plymouthd.conf..."
    $SUDO sed -i 's/^UseSimpledrm=.*/UseSimpledrm=false/' "$ROOTFS_TARGET/etc/plymouth/plymouthd.conf"
fi

# ==============================================================================
# PHASE 6: Final Tasks (Initramfs regeneration and cleanup)
# FASE 6: Tareas Finales del Sistema (Generación de Kernel y Limpieza)
# ==============================================================================

if [ "$DISTRO" = "arch" ]; then
    echo "---🔄 Regenerating initramfs with mkinitcpio ---"
    # Create mkinitcpio hook configuration for live booting
    $SUDO mkdir -p "$ROOTFS_TARGET/etc/mkinitcpio.conf.d"
    echo 'HOOKS=(base udev modconf keyboard kms plymouth archiso archiso_loop_mnt block filesystems)' | $SUDO tee "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/archiso.conf" > /dev/null
    echo 'MODULES=(amdgpu radeon i915 virtio_gpu 9p 9pnet 9pnet_virtio virtio_pci virtio_blk)' | $SUDO tee "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/kms.conf" > /dev/null
    
    # Ensure /usr/share/pixmaps/archlinux-logo.png exists so mkinitcpio's plymouth hook does not error out
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/pixmaps"
    if [ ! -f "$ROOTFS_TARGET/usr/share/pixmaps/archlinux-logo.png" ]; then
        if [ -f "$ROOTFS_TARGET/usr/share/plymouth/themes/pulsar-plymouth/pulsar-logo.png" ]; then
            $SUDO cp "$ROOTFS_TARGET/usr/share/plymouth/themes/pulsar-plymouth/pulsar-logo.png" "$ROOTFS_TARGET/usr/share/pixmaps/archlinux-logo.png"
        else
            echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=" | base64 -d | $SUDO tee "$ROOTFS_TARGET/usr/share/pixmaps/archlinux-logo.png" > /dev/null
        fi
    fi
    
    # Set canonical HOOKS for the installed system.
    # CRITICAL: With the systemd hook, systemd-hibernate-resume handles resume natively.
    # The legacy busybox 'resume' hook MUST NOT coexist with 'systemd' — it causes the
    # kernel to hang after Plymouth splash on resume (waiting for /sys/power/resume that
    # systemd already consumed). Hard-write the canonical line to avoid any stale state
    # from the host's mkinitcpio.conf being inherited by the rootfs.
    if [ -f "$ROOTFS_TARGET/etc/mkinitcpio.conf" ]; then
        echo "⚙️ Estableciendo HOOKS canónicos en /etc/mkinitcpio.conf del sistema instalado..."
        $SUDO sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole plymouth block filesystems fsck btrfs)/' \
            "$ROOTFS_TARGET/etc/mkinitcpio.conf"
        echo "   HOOKS → $(grep '^HOOKS=' "$ROOTFS_TARGET/etc/mkinitcpio.conf")"
    fi
    # Set the GRUB menu entry label to Pulsar OS instead of the archiso default "Arch"
    if [ -f "$ROOTFS_TARGET/etc/default/grub" ]; then
        $SUDO sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Pulsar OS"/' "$ROOTFS_TARGET/etc/default/grub"
    fi
    # Forward initramfs boot messages to Plymouth so the splash always shows the
    # last log line at the bottom. Also done by the pulsaros-plymouth install
    # hook; this second pass guarantees it survives the package install order.
    # Reenviar los mensajes del initramfs a Plymouth para mostrar la última
    # línea de log en el splash. Se repite aquí por si el paquete se reordena.
    $SUDO tee "$ROOTFS_TARGET/tmp/patch-plymouth-msg.awk" > /dev/null <<'AWK'
/^msg\(\) \{/ { inmsg=1 }
inmsg && /^}/ {
    print "    ( command -v plymouth >/dev/null 2>&1 && timeout 2 plymouth --ping >/dev/null 2>&1 && timeout 2 plymouth message --text=\"${*#-n }\" >/dev/null 2>&1 ) &"
    inmsg=0
}
{ print }
AWK
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        INITCPIO_FUNCTIONS=/usr/lib/initcpio/init_functions
        if [ -f \"\$INITCPIO_FUNCTIONS\" ] && ! grep -q 'plymouth message' \"\$INITCPIO_FUNCTIONS\"; then
            awk -f /tmp/patch-plymouth-msg.awk \"\$INITCPIO_FUNCTIONS\" > \"\$INITCPIO_FUNCTIONS.tmp\" && mv \"\$INITCPIO_FUNCTIONS.tmp\" \"\$INITCPIO_FUNCTIONS\"
        fi
        rm -f /tmp/patch-plymouth-msg.awk
    "
    # Clear the Plymouth message line right after the initramfs cleanup hooks,
    # before switch_root, so the splash doesn't freeze showing the last initramfs
    # message once forwarding stops. Also done by the pulsaros-plymouth install
    # hook; this second pass guarantees it survives the package install order.
    # Limpiar la línea de Plymouth tras los cleanup hooks del initramfs, antes
    # del switch_root, para que el splash no se quede congelado en el último
    # mensaje del initramfs. Se repite aquí por si el paquete se reordena.
    $SUDO tee "$ROOTFS_TARGET/tmp/patch-plymouth-clear.awk" > /dev/null <<'AWK'
/^run_hookfunctions .run_cleanuphook. .cleanup hook. .CLEANUPHOOKS$/ {
    print
    print "( command -v plymouth >/dev/null 2>&1 && timeout 2 plymouth message --text=\"\" >/dev/null 2>&1 ) &"
    next
}
{ print }
AWK
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        INITCPIO_INIT=/usr/lib/initcpio/init
        if [ -f \"\$INITCPIO_INIT\" ] && ! grep -q 'plymouth message --text=\"\"' \"\$INITCPIO_INIT\"; then
            awk -f /tmp/patch-plymouth-clear.awk \"\$INITCPIO_INIT\" > \"\$INITCPIO_INIT.tmp\" && mv \"\$INITCPIO_INIT.tmp\" \"\$INITCPIO_INIT\"
        fi
        rm -f /tmp/patch-plymouth-clear.awk
    "
    # Patch the archiso hook to support progress bar/updates on copytoram
    if [ -f "$ROOTFS_TARGET/usr/lib/initcpio/hooks/archiso" ]; then
        echo "--- 🔄 Parcheando hook de archiso para progreso de copytoram ---"
        $SUDO python3 -c '
import sys
target = sys.argv[1]
with open(target, "r") as f:
    content = f.read()

old_block = """    if [ "${copytoram}" = "y" ]; then
        msg -n ":: Copying rootfs image to RAM..."

        # in case we have pv use it to display copy progress feedback otherwise
        # fallback to using plain cp
        if command -v pv >/dev/null 2>&1; then
            echo ""
            (pv "${img}" -o "/run/archiso/copytoram/${img_fullname}")
            local rc=$?
        else
            (cp -- "${img}" "/run/archiso/copytoram/${img_fullname}")
            local rc=$?
        fi

        if [ "$rc" != 0 ]; then
            echo "ERROR: while copy \x27${img}\x27 to \x27/run/archiso/copytoram/${img_fullname}\x27"
            launch_interactive_shell
        fi

        img="/run/archiso/copytoram/${img_fullname}"
        msg "done."
    fi"""

new_block = """    if [ "${copytoram}" = "y" ]; then
        msg -n ":: Copying rootfs image to RAM..."
        total_size=$(stat -c %s "${img}")
        img_dest="/run/archiso/copytoram/${img_fullname}"

        # Detect once whether a splash/plymouth is available. Normal boots use it
        # (or the debug/console boot falls back to a single clean progress line on
        # the console, so the user does not get a flood of logs from the copy).
        have_plymouth=0
        if command -v plymouth >/dev/null 2>&1; then
            timeout 2 plymouth --ping >/dev/null 2>&1 && have_plymouth=1
        fi

        # Start copy in the background
        cp -- "${img}" "${img_dest}" &
        cp_pid=$!

        # The debug boot runs the initramfs hooks with `set -x`, which dumps a
        # trace line for every command in the copy loop and floods the console.
        # Remember the shell option state and silence the trace just for the copy
        # loop, so on a console boot all the user sees is a single percentage.
        _xtrace=0
        case $- in *x*) _xtrace=1 ;; esac
        set +x

        # Monitor progress in the foreground (avoids background subshell TTY/race issues)
        while kill -0 $cp_pid 2>/dev/null; do
            curr_size=$(stat -c %s "${img_dest}" 2>/dev/null || echo 0)
            if [ "$total_size" -gt 0 ] 2>/dev/null; then
                pct=$((curr_size * 100 / total_size))
            else
                pct=0
            fi

            if [ "$have_plymouth" = "1" ]; then
                (
                    timeout 2 plymouth message --text="Copiando sistema a memoria RAM: ${pct}%" >/dev/null 2>&1
                    timeout 2 plymouth --progress="$pct" >/dev/null 2>&1
                ) &
            else
                # No plymouth (debug/console): overwrite a single line. Just a
                # number + % so it does not matter how fast it scrolls.
                printf "\r%3d%%  " "$pct" >/dev/console 2>/dev/null
            fi
            sleep 0.2
        done

        # Re-attach and get exit status of cp
        wait $cp_pid
        rc=$?

        if [ "$have_plymouth" = "1" ]; then
            (
                timeout 2 plymouth message --text="Copiando sistema a memoria RAM: 100%" >/dev/null 2>&1
                timeout 2 plymouth --progress=100 >/dev/null 2>&1
            ) &
        else
            printf "\r100%%  \n" >/dev/console 2>/dev/null
        fi

        # Restore the previous trace state for the remaining boot
        [ "$_xtrace" = "1" ] && set -x

        if [ "$rc" != 0 ]; then
            echo "ERROR: while copy \x27${img}\x27 to \x27/run/archiso/copytoram/${img_fullname}\x27"
            launch_interactive_shell
        fi

        img="/run/archiso/copytoram/${img_fullname}"
        msg "done."
    fi"""

if old_block in content:
    content = content.replace(old_block, new_block)
    with open(target, "w") as f:
        f.write(content)
    print("Patch applied successfully")
else:
    print("Old block not found!")
' "$ROOTFS_TARGET/usr/lib/initcpio/hooks/archiso"
    fi
    # Create a temporary modprobe config to blacklist Nvidia modules inside the initramfs.
    # This prevents the kms/udev hooks from loading nouveau or nvidia drivers during the
    # initramfs stage (avoiding Plymouth freezes on hybrid laptops).
    $SUDO mkdir -p "$ROOTFS_TARGET/etc/modprobe.d"
    cat <<'EOF' | $SUDO tee "$ROOTFS_TARGET/etc/modprobe.d/nvidia-initramfs-blacklist.conf" > /dev/null
blacklist nouveau
blacklist nvidia
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidia_drm
install nouveau /bin/false
install nvidia /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
install nvidia_drm /bin/false
EOF

    # Show the actual error (not swallowed) so a failure aborts visibly.
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        mkinitcpio -P
    "

    # Remove the temporary modprobe config so that the Nvidia drivers can still load
    # normally in the final booted system.
    $SUDO rm -f "$ROOTFS_TARGET/etc/modprobe.d/nvidia-initramfs-blacklist.conf"

    # Enable the Cloudflare WARP daemon (bundled via cloudflare-warp-bin) so the
    # recovery/installer can offer the VPN with a single "warp-cli connect" when
    # the user has network but the Inled repo (apt.inled.es) is censored/blocked.
    if [ -f "$ROOTFS_TARGET/usr/lib/systemd/system/warp-svc.service" ]; then
        echo "🌐 Enabling Cloudflare WARP daemon (warp-svc)..."
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "systemctl enable warp-svc 2>/dev/null || true"
    else
        echo "⚠️ warp-svc.service not present in target — skipping WARP daemon enable (cloudflare-warp-bin may have failed to build)."
    fi

    # Copy skeleton files to live user home directory to ensure all dconf settings and GTK4 themes are applied
    echo "⚙️ Configurando el directorio home del usuario live..."
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        if [ -d /home/live ]; then
            cp -rf /etc/skel/. /home/live/ 2>/dev/null || true
            chown -R live:live /home/live 2>/dev/null || true
        fi
    "
else
    echo "--- 🔄 Finalizando y actualizando initramfs ---"
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        update-initramfs -u -k all
    "
fi

echo "✨ Chroot rootfs listo y estructurado correctamente en: $ROOTFS_TARGET"

# Mark minimal build for post-install package installation by recovery.py
if $MINIMAL; then
    $SUDO touch "$ROOTFS_TARGET/etc/pulsaros-minimal-build"
    echo "🪶 Minimal build marker placed in rootfs."
fi

# ==============================================================================
# PHASE 7: Packaging and Live ISO Generation
# FASE 7: Creación de la Imagen Live ISO
# ==============================================================================
echo "---💿 Creating Pulsar OS Live ISO Image /Creating Pulsar OS Live ISO ---"

$SUDO rm -rf "$ISO_STAGING"
mkdir -p "$ISO_STAGING/live"
mkdir -p "$ISO_STAGING/boot/grub"


if [ "$DISTRO" = "arch" ]; then
    echo "🐧 Copying Kernel and Initrd to the Live ISO (with archiso hooks)..."
    KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
    INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -n 1)
    
    if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
        echo "❌ Error: No kernel or initrd found to copy to the live ISO."
        exit 1
    fi
    
    $SUDO cp "$KERNEL_FILE" "$ISO_STAGING/live/vmlinuz"
    $SUDO cp "$INITRD_FILE" "$ISO_STAGING/live/initrd"

    echo "🧹 Removing file hooks and regenerating initramfs for the installed system..."
    $SUDO rm -f "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/archiso.conf"
    # Show the actual error (not swallowed).
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "mkinitcpio -P"
fi

# 0. Clean temporary logs, test accounts, and unmount virtual filesystems prior to packaging
echo "🧹 Sanitizing rootfs target (cleaning test logs, temporary accounts, and cache)..."
$SUDO rm -rf "$ROOTFS_TARGET"/tmp/* "$ROOTFS_TARGET"/var/tmp/* "$ROOTFS_TARGET"/var/log/* 2>/dev/null || true
$SUDO rm -f "$ROOTFS_TARGET"/etc/sudoers.d/pulsaros-user-* "$ROOTFS_TARGET"/etc/sudoers.d/jaime 2>/dev/null || true
$SUDO rm -f "$ROOTFS_TARGET"/var/lib/AccountsService/users/* 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET/home" -mindepth 1 -maxdepth 1 ! -name 'live' -exec rm -rf {} + 2>/dev/null || true

echo "Unmounting virtual filesystems in target..."
unmount_tree "$ROOTFS_TARGET"

    # Build dedicated Debian Recovery environment (always — base is cached internally)
    REC_OUT="$SCRIPT_DIR/build/recovery-out"
    if [ -f "$SCRIPT_DIR/build-recovery-image.sh" ]; then
        if [ ! -f "$REC_OUT/filesystem.squashfs" ]; then
            (
                flock -x 200
                if [ ! -f "$REC_OUT/filesystem.squashfs" ]; then
                    echo "📦 Building dedicated Debian Recovery environment..."
                    $SUDO bash "$SCRIPT_DIR/build-recovery-image.sh" || echo "⚠️ Notice: Recovery build finished with warnings, continuing..."
                fi
            ) 200>"$BUILD_DIR/.recovery.lock"
        fi
    fi

    if [ -f "$REC_OUT/filesystem.squashfs" ]; then
        echo "📦 Staging dedicated Debian Recovery environment into target rootfs and ISO..."
        $SUDO mkdir -p "$ISO_STAGING/recovery" "$ISO_STAGING/recovery/live" "$ROOTFS_TARGET/recovery" "$ROOTFS_TARGET/live" "$ROOTFS_TARGET/usr/share/pulsaros-recovery"
        # Hardlinks for ISO_STAGING (won't be rsync'd, saves disk during build)
        $SUDO ln -f "$REC_OUT/filesystem.squashfs" "$ISO_STAGING/recovery/filesystem.squashfs"
        $SUDO ln -f "$REC_OUT/filesystem.squashfs" "$ISO_STAGING/recovery/live/filesystem.squashfs"
        # Copies for ROOTFS_TARGET (rsync'd to disk — hardlinks cause cross-device link errors)
        $SUDO cp -f "$REC_OUT/filesystem.squashfs" "$ROOTFS_TARGET/recovery/filesystem.squashfs"
        $SUDO cp -f "$REC_OUT/filesystem.squashfs" "$ROOTFS_TARGET/live/filesystem.squashfs"
        $SUDO cp -f "$REC_OUT/filesystem.squashfs" "$ROOTFS_TARGET/usr/share/pulsaros-recovery/recovery-filesystem.squashfs"
        if [ -f "$REC_OUT/vmlinuz-recovery" ]; then
            $SUDO ln -f "$REC_OUT/vmlinuz-recovery" "$ISO_STAGING/recovery/vmlinuz-recovery"
            $SUDO cp -f "$REC_OUT/vmlinuz-recovery" "$ROOTFS_TARGET/recovery/vmlinuz-recovery"
            $SUDO cp -f "$REC_OUT/vmlinuz-recovery" "$ROOTFS_TARGET/usr/share/pulsaros-recovery/vmlinuz-recovery"
        else
            echo "❌ Error: Recovery kernel missing at $REC_OUT/vmlinuz-recovery"
            exit 1
        fi
        if [ -f "$REC_OUT/initramfs-recovery.img" ]; then
            $SUDO ln -f "$REC_OUT/initramfs-recovery.img" "$ISO_STAGING/recovery/initramfs-recovery.img"
            $SUDO cp -f "$REC_OUT/initramfs-recovery.img" "$ROOTFS_TARGET/recovery/initramfs-recovery.img"
            $SUDO cp -f "$REC_OUT/initramfs-recovery.img" "$ROOTFS_TARGET/usr/share/pulsaros-recovery/initramfs-recovery.img"
        else
            echo "❌ Error: Recovery initramfs missing at $REC_OUT/initramfs-recovery.img"
            exit 1
        fi
    fi

    # Sync latest local development packages directly into target rootfs
    echo "📦 Syncing latest local workspace components into target rootfs..."
    # 1. pulsaros-recovery (recovery.py, rust assistant)
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/bin" "$ROOTFS_TARGET/usr/share/pulsaros-recovery"
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/bin/pulsar-recovery-assistant" "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
    $SUDO cp -rf "$PULSAR_ROOT/PKG/pulsaros-recovery/usr/share/pulsaros-recovery/." "$ROOTFS_TARGET/usr/share/pulsaros-recovery/" 2>/dev/null || true
    # 2. pulsaros-hibernate
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/lib/pulsaros" "$ROOTFS_TARGET/usr/lib/systemd/system-sleep" "$ROOTFS_TARGET/etc/systemd/system"
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-hibernate/usr/lib/pulsaros/sleep-progress" "$ROOTFS_TARGET/usr/lib/pulsaros/" 2>/dev/null || true
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-hibernate/usr/lib/pulsaros/resume-session" "$ROOTFS_TARGET/usr/lib/pulsaros/" 2>/dev/null || true
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-hibernate/usr/lib/pulsaros/verify-resume-offset" "$ROOTFS_TARGET/usr/lib/pulsaros/" 2>/dev/null || true
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-hibernate/usr/lib/systemd/system-sleep/pulsaros-hibernate.sh" "$ROOTFS_TARGET/usr/lib/systemd/system-sleep/" 2>/dev/null || true
    $SUDO cp -rf "$PULSAR_ROOT/PKG/pulsaros-hibernate/etc/systemd/system/." "$ROOTFS_TARGET/etc/systemd/system/" 2>/dev/null || true
    $SUDO chmod +x "$ROOTFS_TARGET/usr/lib/pulsaros/sleep-progress" \
                   "$ROOTFS_TARGET/usr/lib/pulsaros/resume-session" \
                   "$ROOTFS_TARGET/usr/lib/pulsaros/verify-resume-offset" \
                   "$ROOTFS_TARGET/usr/lib/systemd/system-sleep/pulsaros-hibernate.sh" 2>/dev/null || true
    # Enable the post-resume session restoration service (WantedBy=graphical.target)
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c \
        "systemctl enable pulsaros-resume-session.service 2>/dev/null || true" 2>/dev/null || true
    # 3. pulsaros-global-menu
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-global-menu/usr/bin/pulsaros-power-action" "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
    $SUDO cp -f "$PULSAR_ROOT/PKG/pulsaros-global-menu/usr/bin/pulsaros-setup-hibernation" "$ROOTFS_TARGET/usr/bin/" 2>/dev/null || true
    $SUDO chmod +x "$ROOTFS_TARGET/usr/bin/pulsaros-power-action" "$ROOTFS_TARGET/usr/bin/pulsaros-setup-hibernation" 2>/dev/null || true

    # Remove unwanted GNOME extensions from rootfs
    echo "🧹 Removing unwanted GNOME extensions (places-menu, window-list)..."
    $SUDO rm -rf "$ROOTFS_TARGET/usr/share/gnome-shell/extensions/places-menu@gnome-shell-extensions.gcampax.github.com" \
                 "$ROOTFS_TARGET/usr/share/gnome-shell/extensions/window-list@gnome-shell-extensions.gcampax.github.com" \
                 "$ROOTFS_TARGET/usr/share/gnome-shell/extensions/search-light@icedman.github.com" 2>/dev/null || true

# ── Deep clean rootfs before compression ──────────────────────────────────
echo "🧹 Deep-cleaning rootfs before SquashFS compression..."
# Remove documentation and locale data to save space
$SUDO find "$ROOTFS_TARGET/usr/share/doc" -type f -delete 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET/usr/share/man" -type f -delete 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET/usr/share/gtk-doc" -type d -exec rm -rf {} + 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET/usr/share/info" -type f -delete 2>/dev/null || true
# Keep only essential locales (es, en, C)
$SUDO find "$ROOTFS_TARGET/usr/share/locale" -mindepth 1 -maxdepth 1 \
    ! -name 'es' ! -name 'es_*' ! -name 'en' ! -name 'en_*' ! -name 'C' \
    -exec rm -rf {} + 2>/dev/null || true
# Remove Python cache files
$SUDO find "$ROOTFS_TARGET" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
$SUDO find "$ROOTFS_TARGET" -name "*.pyc" -delete 2>/dev/null || true
# Remove debug symbols
$SUDO find "$ROOTFS_TARGET" -name "*.debug" -delete 2>/dev/null || true
# Kickstart icon cache rebuild (do NOT delete icon themes — it breaks cursors
# and app icons, e.g. breeze for SDDM).
# Actualiza la caché de iconos (NO borrar temas — rompe cursores e iconos).
$SUDO find "$ROOTFS_TARGET/usr/share/icons" -type f -name 'icon-theme.cache' -delete 2>/dev/null || true
# Remove pacman package cache inside rootfs
$SUDO rm -rf "$ROOTFS_TARGET/var/cache/pacman/pkg"/* 2>/dev/null || true
# Remove any remaining build artifacts
$SUDO rm -rf "$ROOTFS_TARGET/var/cache/pacman/sync"/* 2>/dev/null || true
# Remove unused systemd generators and tmpfiles
$SUDO rm -rf "$ROOTFS_TARGET/usr/lib/systemd/system-generators"/*.py 2>/dev/null || true
# Remove more redundant files
$SUDO find "$ROOTFS_TARGET/usr/share/X11/locale" -mindepth 1 -maxdepth 1 \
    ! -name 'en_US.UTF-8' ! -name 'es_ES.UTF-8' -exec rm -rf {} + 2>/dev/null || true
echo "✅ Rootfs cleaned."

# 1. Compress rootfs into SquashFS / Comprimir el rootfs en SquashFS
echo "📦 Compressing rootfs into SquashFS (zstd level 19)..."
# Exclude dynamic/temp directories and virtual filesystems to save space and prevent errors
# Excluimos directorios dinámicos, temporales y sistemas de archivos virtuales para ahorrar espacio y evitar errores
    if [ "$DISTRO" = "arch" ]; then
        SQUASHFS_OUT="$ISO_STAGING/live/x86_64/airootfs.sfs"
        $SUDO mkdir -p "$ISO_STAGING/live/x86_64"
    else
        SQUASHFS_OUT="$ISO_STAGING/live/filesystem.squashfs"
    fi
    $SUDO env "PATH=/usr/bin:/usr/sbin:/sbin:/bin:$PATH" mksquashfs "$ROOTFS_TARGET" "$SQUASHFS_OUT" \
        -noappend \
        -comp zstd -Xcompression-level 19 \
        -processors "$BUILD_PROCESSORS" \
        -e proc/* \
        -e sys/* \
        -e dev/* \
        -e run/* \
        -e tmp/* \
        -e var/tmp/* \
        -e var/log/* \
        -e root/.bash_history

    # Also export standalone recovery SquashFS image for local recovery partition and GitHub Releases
    VER_SUFFIX=""
    if [ -n "$PULSAR_VERSION" ]; then
        VER_SUFFIX="-${PULSAR_VERSION}"
    fi
    RECOVERY_SQUASHFS="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}-${BOOTLOADER}${VER_SUFFIX}.squashfs"
    echo "📦 Exporting standalone recovery SquashFS to $RECOVERY_SQUASHFS..."
    $SUDO cp -f "$SQUASHFS_OUT" "$RECOVERY_SQUASHFS"

    # Stage base OS image into standard paths inside ISO staging for offline recovery partition deployment
    $SUDO mkdir -p "$ISO_STAGING/images" "$ISO_STAGING/arch/x86_64" "$ROOTFS_TARGET/recovery/images"
    # Hardlinks for ISO_STAGING (won't be rsync'd)
    $SUDO ln -f "$SQUASHFS_OUT" "$ISO_STAGING/images/pulsaros-base.squashfs"
    $SUDO ln -f "$SQUASHFS_OUT" "$ISO_STAGING/arch/x86_64/airootfs.sfs"
    # Copy for ROOTFS_TARGET (rsync'd to disk — hardlinks cause cross-device link errors)
    $SUDO cp -f "$SQUASHFS_OUT" "$ROOTFS_TARGET/recovery/images/pulsaros-base.squashfs"

# 2. Copy Kernel and Initrd to ISO staging / Copiar Kernel e Initrd al directorio de la ISO
if [ "$DISTRO" = "arch" ]; then
    # Already copied and configured above, just define the variables for subsequent steps
    KERNEL_FILE="$ISO_STAGING/live/vmlinuz"
    INITRD_FILE="$ISO_STAGING/live/initrd"
else
    echo "🐧 Copiando Kernel e Initrd... / Copying Kernel and Initrd..."
    KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
    INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initrd.img-* 2>/dev/null | head -n 1)

    if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
        echo "❌ Error: No se encontró kernel o initrd en el chroot target. / Error: Kernel or initrd not found in target chroot."
        exit 1
    fi

    $SUDO cp "$KERNEL_FILE" "$ISO_STAGING/live/vmlinuz"
    $SUDO cp "$INITRD_FILE" "$ISO_STAGING/live/initrd"
fi

if [ "$DISTRO" = "arch" ]; then
    KERNEL_PARAMS="archisobasedir=live archisolabel=PULSAR_ISO cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 --"
    RAM_PARAMS="archisobasedir=live archisolabel=PULSAR_ISO cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.use-simpledrm=0 quiet splash loglevel=3 --"
    DEBUG_PARAMS="archisobasedir=live archisolabel=PULSAR_ISO cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.ignore-serial-consoles loglevel=7 rd.debug --"
    LEGACY_PARAMS="archisobasedir=live archisolabel=PULSAR_ISO cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 --"
else
    KERNEL_PARAMS="boot=live components username=live autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 noprompt --"
    RAM_PARAMS="boot=live components username=live autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes toram plymouth.use-simpledrm=0 quiet splash loglevel=3 noprompt --"
    DEBUG_PARAMS="boot=live components username=live autologin cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes toram plymouth.ignore-serial-consoles loglevel=7 rd.debug noprompt --"
    LEGACY_PARAMS="boot=live components username=live autologin cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 noprompt --"
fi

resolve_boot_icons() {
    if [ -d "$ROOTFS_TARGET/usr/share/pulsar-boot-icons" ]; then
        echo "$ROOTFS_TARGET/usr/share/pulsar-boot-icons"
        return
    fi
    if [ -d "$ISO_DIR/../PKG/pulsar-boot-icons" ]; then
        echo "$ISO_DIR/../PKG/pulsar-boot-icons"
        return
    fi
    if [ -d "$ISO_DIR/boot-icons" ]; then
        echo "$ISO_DIR/boot-icons"
        return
    fi
    echo "🌐 Descargando pulsar-boot-icons desde Inled-Pulsar-OS/PKG..." >&2
    local icons_tmp_repo="$BUILD_DIR/pkg-repo-temp-${VARIANT_NAME}-${BOOTLOADER}-$$"
    local icons_tmp_dest="$BUILD_DIR/pulsar-boot-icons-${VARIANT_NAME}-${BOOTLOADER}-$$"
    $SUDO rm -rf "$icons_tmp_repo" "$icons_tmp_dest"
    $SUDO git -c http.version=HTTP/1.1 clone --depth=1 "https://github.com/Inled-Pulsar-OS/PKG.git" "$icons_tmp_repo" 2>/dev/null || true
    if [ -d "$icons_tmp_repo/pulsar-boot-icons" ]; then
        $SUDO mkdir -p "$icons_tmp_dest"
        $SUDO cp -rf "$icons_tmp_repo/pulsar-boot-icons"/* "$icons_tmp_dest/"
    fi
    $SUDO rm -rf "$icons_tmp_repo"
    echo "$icons_tmp_dest"
}

if [ "$BOOTLOADER" = "grub" ]; then
    # --------------------------------------------------------------------------
    # GRUB BOOTLOADER PACKAGING
    # --------------------------------------------------------------------------
    echo "⚙️ Configuring GRUB for ISO..."
    $SUDO mkdir -p "$ISO_STAGING/boot/grub"
    
    # Copy the custom GRUB theme to the ISO staging directory / Copiar el tema de GRUB personalizado
    GRUB_THEME_SRC=""
    if [ -d "$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window" ]; then
        GRUB_THEME_SRC="$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window"
    elif [ -d "$ROOTFS_TARGET/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$ROOTFS_TARGET/boot/grub/themes/grub-theme"
    elif [ -d "$SCRIPT_DIR/../PKG/build/pkg-staging/pulsaros-grub/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$SCRIPT_DIR/../PKG/build/pkg-staging/pulsaros-grub/boot/grub/themes/grub-theme"
    elif [ -d "$SCRIPT_DIR/../PKG/arch/pkgbuilds/pulsaros-grub/src/staging/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$SCRIPT_DIR/../PKG/arch/pkgbuilds/pulsaros-grub/src/staging/boot/grub/themes/grub-theme"
    fi
    if [ -z "$GRUB_THEME_SRC" ] && [ -f "$SCRIPT_DIR/../PKG/pulsaros-grub/prepare-assets.sh" ]; then
        echo "🎨 Preparando tema de GRUB para la ISO..."
        TMP_GRUB_STAGE="/tmp/iso-grub-theme-stage-${VARIANT_NAME}-${BOOTLOADER}-$$"
        $SUDO rm -rf "$TMP_GRUB_STAGE"
        mkdir -p "$TMP_GRUB_STAGE"
        bash "$SCRIPT_DIR/../PKG/pulsaros-grub/prepare-assets.sh" "$TMP_GRUB_STAGE" >/dev/null 2>&1 || true
        if [ -d "$TMP_GRUB_STAGE/boot/grub/themes/grub-theme" ]; then
            GRUB_THEME_SRC="$TMP_GRUB_STAGE/boot/grub/themes/grub-theme"
        fi
    fi
    if [ -n "$GRUB_THEME_SRC" ] && [ -d "$GRUB_THEME_SRC" ]; then
        echo "🎨 Copying Pulsar OS GRUB theme ($GRUB_THEME_SRC) to the ISO staging..."
        $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes/Particle-circle-window"
        $SUDO cp -rf "$GRUB_THEME_SRC"/* "$ISO_STAGING/boot/grub/themes/Particle-circle-window/"
        if [ -d "$ISO_STAGING/boot/grub/themes/Particle-circle-window/common" ]; then
            $SUDO cp -f "$ISO_STAGING/boot/grub/themes/Particle-circle-window/common"/*.pf2 "$ISO_STAGING/boot/grub/themes/Particle-circle-window/" 2>/dev/null || true
        fi
    fi
    BOOT_ICONS_DIR="$(resolve_boot_icons)"
    if [ -d "$BOOT_ICONS_DIR/grub" ]; then
        $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes/Particle-circle-window/icons"
        $SUDO cp -f "$BOOT_ICONS_DIR/grub"/icons-1080p/*.png "$ISO_STAGING/boot/grub/themes/Particle-circle-window/icons/" 2>/dev/null || true
    fi
    
    # Copiar la fuente unicode.pf2 para evitar caracteres rotos [?] en el menú de GRUB
    $SUDO mkdir -p "$ISO_STAGING/boot/grub/fonts"
    if [ -f "/usr/share/grub/unicode.pf2" ]; then
        $SUDO cp "/usr/share/grub/unicode.pf2" "$ISO_STAGING/boot/grub/fonts/"
    elif [ -f "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" ]; then
        $SUDO cp "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" "$ISO_STAGING/boot/grub/fonts/"
    fi
    
    # Create GRUB bootloader configuration / Crear menú de arranque de GRUB
    echo "⚙️ Configurando el menú de arranque GRUB de la ISO... / Configuring GRUB boot menu..."

    cat <<EOF | $SUDO tee "$ISO_STAGING/boot/grub/grub.cfg" > /dev/null
set default="0"
set timeout=10

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

menuentry "Pulsar OS Live (RAM)" --class pulsaros-ram --class gnu-linux --class os {
    linux /live/vmlinuz $RAM_PARAMS
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Normal)" --class pulsaros --class gnu-linux --class os {
    linux /live/vmlinuz $KERNEL_PARAMS
    initrd /live/initrd
}

menuentry "Pulsar OS Live (No Plymouth / Debug)" --class pulsaros-debug --class terminal --class gnu-linux {
    linux /live/vmlinuz $DEBUG_PARAMS
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Legacy Hardware / GPU nomodeset)" --class pulsaros-legacy --class driver --class gnu-linux {
    linux /live/vmlinuz $LEGACY_PARAMS
    initrd /live/initrd
}
EOF

    # Create GRUB loopback configuration for Ventoy compatibility
    echo "⚙️ Creando el menú de arranque loopback.cfg para Ventoy... / Creating loopback.cfg for Ventoy..."
    $SUDO mkdir -p "$ISO_STAGING/boot/grub"
    cat <<'EOF' | $SUDO tee "$ISO_STAGING/boot/grub/loopback.cfg" > /dev/null
# Search for the device containing the ISO file
search --no-floppy --set=imgdev --file $isofile
probe -u $imgdev --set=imgdevuuid

set default="0"
set timeout=10

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

menuentry "Pulsar OS Live (RAM)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.use-simpledrm=0 quiet splash loglevel=3 --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Normal)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (No Plymouth / Debug)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.ignore-serial-consoles loglevel=7 rd.debug --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Legacy Hardware / GPU nomodeset)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 --
    initrd /live/initrd
}
EOF

    VER_SUFFIX=""
    if [ -n "$PULSAR_VERSION" ]; then
        VER_SUFFIX="-${PULSAR_VERSION}"
    fi

    if $WITH_NVIDIA; then
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}${VER_SUFFIX}-nvidia.iso"
    else
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}${VER_SUFFIX}.iso"
    fi
    # Create a temporary xorriso wrapper to force -iso-level 3
    # which allows files larger than 4GB (ISO 9660 Level 3 multi-extents)
    # We also set the volume label to PULSAR_ISO so the archiso hook can locate it,
    # and strip out Apple/HFS+/APM arguments to prevent label collision on physical USB drives.
    WRAPPER_PATH="/tmp/xorriso-wrapper-${VARIANT_NAME}-${BOOTLOADER}-$$"
    cat <<'EOF' > "$WRAPPER_PATH"
#!/bin/bash
args=()
i=1
while [ $i -le $# ]; do
    arg="${!i}"
    case "$arg" in
        -hfsplus)
            # Skip this argument
            ;;
        -apm-block-size)
            # Skip this and the next argument (the size)
            i=$((i + 1))
            ;;
        -hfsplus-file-creator-type)
            # Skip this and the next three arguments
            i=$((i + 3))
            ;;
        -hfs-bless-by)
            # Skip this and the next two arguments
            i=$((i + 2))
            ;;
        -hfsplus-serial-number)
            # Skip this and the next argument
            i=$((i + 1))
            ;;
        *)
            args+=("$arg")
            ;;
    esac
    i=$((i + 1))
done

exec xorriso "${args[@]}" -iso-level 3 -volid PULSAR_ISO
EOF
    chmod +x "$WRAPPER_PATH"

    echo "💿 Generando archivo ISO GRUB en / Generating GRUB ISO file at: $ISO_OUTPUT..."
    $SUDO grub-mkrescue --xorriso="$WRAPPER_PATH" -o "$ISO_OUTPUT" "$ISO_STAGING"
    rm -f "$WRAPPER_PATH"
    $SUDO ln -sfn "$(basename "$ISO_OUTPUT")" "$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}-grub${VER_SUFFIX}.iso" 2>/dev/null || true

else
    # --------------------------------------------------------------------------
    # rEFInd BOOTLOADER PACKAGING
    # --------------------------------------------------------------------------
    echo "💿 Creando imagen EFI bootable con rEFInd... / Creating bootable EFI image with rEFInd..."
    $SUDO mkdir -p "$ISO_STAGING/boot"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT"
    EFI_IMG="$ISO_STAGING/boot/efi.img"

    # Create a 450MB empty file and format it as FAT16 (eliminates FAT32 cluster warnings and has space for both regular and recovery kernels/initrds)
    # Crear un archivo vacío de 450MB y formatearlo en FAT16
    $SUDO dd if=/dev/zero of="$EFI_IMG" bs=1M count=450 2>/dev/null
    $SUDO mkfs.vfat -F 16 "$EFI_IMG" >/dev/null

    REFIND_CONF_TMP="$BUILD_DIR/refind-${VARIANT_NAME}-${BOOTLOADER}-$$.conf"
    REFIND_MINIMAL_CONF_TMP="$BUILD_DIR/refind-minimal-${VARIANT_NAME}-${BOOTLOADER}-$$.conf"
    REFIND_THEME_DIR_TMP="$BUILD_DIR/refind-mac-theme-${VARIANT_NAME}-${BOOTLOADER}-$$"

    # Create temporary refind.conf for the ISO boot (full config with theme — goes inside efi.img)
    cat <<EOF > "$REFIND_CONF_TMP"
timeout 10
enable_mouse
mouse_speed 4
mouse_size 16
resolution max
scanfor manual
dont_scan_dirs EFI,live,recovery,boot,EFI/BOOT/drivers_x64,themes
dont_scan_files *
default_selection "+,pulsaros,Pulsar OS Live (RAM)"
include themes/rEFInd-Regular-Dark/theme.conf

menuentry "Pulsar OS Live (RAM)" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_toram.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$RAM_PARAMS"
}

menuentry "Pulsar OS Live (Normal)" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_normal.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$KERNEL_PARAMS"
}

menuentry "Pulsar OS Live (No Plymouth / Debug)" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_debug.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$DEBUG_PARAMS"
}

menuentry "Pulsar OS Live (Legacy Hardware / GPU nomodeset)" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_old.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$LEGACY_PARAMS"
}
EOF

    # Minimal refind.conf for the ISO root (no showtools, no theme — avoids duplicate tool buttons
    # when rEFInd scans both ISO9660 and FAT efi.img filesystems)
    cat <<EOF > "$REFIND_MINIMAL_CONF_TMP"
timeout 10
resolution max
scanfor manual
dont_scan_dirs EFI,live,recovery,boot,EFI/BOOT/drivers_x64,themes
dont_scan_files *
default_selection "+,pulsaros,Pulsar OS Live (RAM)"

menuentry "Pulsar OS Live (RAM)" {
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$RAM_PARAMS"
}

menuentry "Pulsar OS Live (Normal)" {
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$KERNEL_PARAMS"
}

menuentry "Pulsar OS Live (No Plymouth / Debug)" {
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$DEBUG_PARAMS"
}

menuentry "Pulsar OS Live (Legacy Hardware / GPU nomodeset)" {
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "$LEGACY_PARAMS"
}
EOF

    # Get the theme (copy from installed rootfs package, local source, or GitHub fallback)
    echo "🎨 Obteniendo tema macOS de rEFInd..."
    $SUDO rm -rf "$REFIND_THEME_DIR_TMP"
    if [ -d "$ROOTFS_TARGET/usr/share/refind/themes/rEFInd-Regular-Dark" ]; then
        echo "📂 Copiando tema rEFInd desde el paquete pulsaros-refind instalado en rootfs..."
        $SUDO cp -r "$ROOTFS_TARGET/usr/share/refind/themes/rEFInd-Regular-Dark" "$REFIND_THEME_DIR_TMP"
    elif [ -d "$ISO_DIR/../refind" ]; then
        echo "📂 Copiando tema local desde: $ISO_DIR/../refind"
        $SUDO cp -r "$ISO_DIR/../refind" "$REFIND_THEME_DIR_TMP"
        $SUDO rm -rf "$REFIND_THEME_DIR_TMP/.git"
    else
        echo "🌐 Descargando tema desde GitHub..."
        $SUDO git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --depth=1 "https://github.com/Inled-Pulsar-OS/refind-mac-theme" "$REFIND_THEME_DIR_TMP"
    fi
    $SUDO sed -i '/#MENUENTRIES/q' "$REFIND_THEME_DIR_TMP/theme.conf"
    BOOT_ICONS_DIR="$(resolve_boot_icons)"
    if [ -d "$BOOT_ICONS_DIR" ]; then
        echo "📦 Asegurando iconos de arranque live personalizados en rEFInd ISO..."
        $SUDO cp -f "$BOOT_ICONS_DIR/toram.png" "$REFIND_THEME_DIR_TMP/icons/os_pulsaros_toram.png" 2>/dev/null || true
        $SUDO cp -f "$BOOT_ICONS_DIR/normal.png" "$REFIND_THEME_DIR_TMP/icons/os_pulsaros_normal.png" 2>/dev/null || true
        $SUDO cp -f "$BOOT_ICONS_DIR/os_pulsaros_normal.png" "$REFIND_THEME_DIR_TMP/icons/os_pulsaros_normal.png" 2>/dev/null || true
        $SUDO cp -f "$BOOT_ICONS_DIR/debug-noplymouth.png" "$REFIND_THEME_DIR_TMP/icons/os_pulsaros_debug.png" 2>/dev/null || true
        $SUDO cp -f "$BOOT_ICONS_DIR/old.png" "$REFIND_THEME_DIR_TMP/icons/os_pulsaros_old.png" 2>/dev/null || true
        if [ -f "$BOOT_ICONS_DIR/os_recovery.png" ]; then
            $SUDO cp -f "$BOOT_ICONS_DIR/os_recovery.png" "$REFIND_THEME_DIR_TMP/icons/os_recovery.png" 2>/dev/null || true
        elif [ -f "$BOOT_ICONS_DIR/recovery.png" ]; then
            $SUDO cp -f "$BOOT_ICONS_DIR/recovery.png" "$REFIND_THEME_DIR_TMP/icons/os_recovery.png" 2>/dev/null || true
        fi
    fi

    # Determine the location of rEFInd files in the chroot (Debian has it under /usr/share/refind/refind, Arch directly under /usr/share/refind)
    REFIND_SHARE_DIR="$ROOTFS_TARGET/usr/share/refind"
    if [ -d "$ROOTFS_TARGET/usr/share/refind/refind" ]; then
        REFIND_SHARE_DIR="$ROOTFS_TARGET/usr/share/refind/refind"
    fi

    # 1. Populate the ISO root /EFI/BOOT folder for direct UEFI boot (resolves QEMU boot problems)
    echo "📂 Copiando archivos de rEFInd, kernel e initrd a la raíz de la ISO staging..."
    $SUDO cp "$REFIND_SHARE_DIR/refind_x64.efi" "$ISO_STAGING/EFI/BOOT/bootx64.efi"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT/drivers_x64"
    $SUDO cp "$REFIND_SHARE_DIR/drivers_x64/"*iso9660*.efi "$ISO_STAGING/EFI/BOOT/drivers_x64/" 2>/dev/null || true
    $SUDO cp "$REFIND_MINIMAL_CONF_TMP" "$ISO_STAGING/EFI/BOOT/refind.conf"
    
    # Copy kernels and initrds directly to the UEFI boot folder on the ISO
    $SUDO cp "$ISO_STAGING/live/vmlinuz" "$ISO_STAGING/EFI/BOOT/vmlinuz"
    $SUDO cp "$ISO_STAGING/live/initrd" "$ISO_STAGING/EFI/BOOT/initrd"
    if [ -f "$ISO_STAGING/recovery/vmlinuz-recovery" ]; then
        $SUDO cp "$ISO_STAGING/recovery/vmlinuz-recovery" "$ISO_STAGING/EFI/BOOT/vmlinuz-recovery"
    fi
    if [ -f "$ISO_STAGING/recovery/initramfs-recovery.img" ]; then
        $SUDO cp "$ISO_STAGING/recovery/initramfs-recovery.img" "$ISO_STAGING/EFI/BOOT/initramfs-recovery.img"
    fi

    # 2. Populate the efi.img for El Torito boot using mtools (resolves cluster size warnings)
    echo "📥 Copiando archivos a efi.img usando mtools..."
    $SUDO mmd -i "$EFI_IMG" ::/EFI
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/drivers_x64
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/themes
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/icons

    $SUDO mcopy -i "$EFI_IMG" "$REFIND_SHARE_DIR/refind_x64.efi" ::/EFI/BOOT/bootx64.efi
    $SUDO mcopy -i "$EFI_IMG" "$REFIND_SHARE_DIR/drivers_x64/"*iso9660*.efi ::/EFI/BOOT/drivers_x64/ 2>/dev/null || true
    $SUDO mcopy -i "$EFI_IMG" "$REFIND_CONF_TMP" ::/EFI/BOOT/refind.conf
    $SUDO mcopy -s -i "$EFI_IMG" "$REFIND_SHARE_DIR/icons"/* ::/EFI/BOOT/icons/
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/themes/rEFInd-Regular-Dark
    $SUDO mcopy -s -i "$EFI_IMG" "$REFIND_THEME_DIR_TMP"/* ::/EFI/BOOT/themes/rEFInd-Regular-Dark/
    
    # Copy kernels and initrds directly to the efi.img FAT volume using mtools
    $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/vmlinuz" ::/EFI/BOOT/vmlinuz
    $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/initrd" ::/EFI/BOOT/initrd
    if [ -f "$ISO_STAGING/recovery/vmlinuz-recovery" ]; then
        $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/recovery/vmlinuz-recovery" ::/EFI/BOOT/vmlinuz-recovery
    fi
    if [ -f "$ISO_STAGING/recovery/initramfs-recovery.img" ]; then
        $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/recovery/initramfs-recovery.img" ::/EFI/BOOT/initramfs-recovery.img
    fi

    # Cleanup temp build files
    $SUDO rm -f "$REFIND_CONF_TMP"
    $SUDO rm -f "$REFIND_MINIMAL_CONF_TMP"
    $SUDO rm -rf "$REFIND_THEME_DIR_TMP"

    # Copy the custom GRUB theme to the ISO staging directory for Ventoy compatibility
    GRUB_THEME_SRC=""
    if [ -d "$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window" ]; then
        GRUB_THEME_SRC="$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window"
    elif [ -d "$ROOTFS_TARGET/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$ROOTFS_TARGET/boot/grub/themes/grub-theme"
    elif [ -d "$SCRIPT_DIR/../PKG/build/pkg-staging/pulsaros-grub/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$SCRIPT_DIR/../PKG/build/pkg-staging/pulsaros-grub/boot/grub/themes/grub-theme"
    elif [ -d "$SCRIPT_DIR/../PKG/arch/pkgbuilds/pulsaros-grub/src/staging/boot/grub/themes/grub-theme" ]; then
        GRUB_THEME_SRC="$SCRIPT_DIR/../PKG/arch/pkgbuilds/pulsaros-grub/src/staging/boot/grub/themes/grub-theme"
    fi
    if [ -n "$GRUB_THEME_SRC" ] && [ -d "$GRUB_THEME_SRC" ]; then
        $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes/Particle-circle-window"
        $SUDO cp -rf "$GRUB_THEME_SRC"/* "$ISO_STAGING/boot/grub/themes/Particle-circle-window/"
        if [ -d "$ISO_STAGING/boot/grub/themes/Particle-circle-window/common" ]; then
            $SUDO cp -f "$ISO_STAGING/boot/grub/themes/Particle-circle-window/common"/*.pf2 "$ISO_STAGING/boot/grub/themes/Particle-circle-window/" 2>/dev/null || true
        fi
        if [ -d "$BOOT_ICONS_DIR/grub" ]; then
            $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes/Particle-circle-window/icons"
            $SUDO cp -f "$BOOT_ICONS_DIR/grub"/icons-1080p/*.png "$ISO_STAGING/boot/grub/themes/Particle-circle-window/icons/" 2>/dev/null || true
        fi
    fi
    # Copy unicode.pf2 for Ventoy's GRUB menus
    $SUDO mkdir -p "$ISO_STAGING/boot/grub/fonts"
    if [ -f "/usr/share/grub/unicode.pf2" ]; then
        $SUDO cp "/usr/share/grub/unicode.pf2" "$ISO_STAGING/boot/grub/fonts/"
    elif [ -f "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" ]; then
        $SUDO cp "$ROOTFS_TARGET/usr/share/grub/unicode.pf2" "$ISO_STAGING/boot/grub/fonts/"
    fi

    # Create GRUB loopback configuration for Ventoy compatibility
    echo "⚙️ Creando el menú de arranque loopback.cfg para Ventoy... / Creating loopback.cfg for Ventoy..."
    $SUDO mkdir -p "$ISO_STAGING/boot/grub"
    cat <<'EOF' | $SUDO tee "$ISO_STAGING/boot/grub/loopback.cfg" > /dev/null
# Search for the device containing the ISO file
search --no-floppy --set=imgdev --file $isofile
probe -u $imgdev --set=imgdevuuid

set default="0"
set timeout=10

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

menuentry "Pulsar OS Live (RAM)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.use-simpledrm=0 quiet splash loglevel=3 --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Normal)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 amdgpu.dcdebugmask=0x10 radeon.modeset=1 nvme_load=yes plymouth.use-simpledrm=0 quiet splash loglevel=3 --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (No Plymouth / Debug)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 radeon.modeset=1 nvme_load=yes copytoram=y plymouth.ignore-serial-consoles loglevel=7 rd.debug --
    initrd /live/initrd
}

menuentry "Pulsar OS Live (Legacy Hardware / GPU nomodeset)" {
    linux /live/vmlinuz archisobasedir=live archisolabel=PULSAR_ISO img_dev=UUID=$imgdevuuid img_loop=$isofile cow_spacesize=4G module_blacklist=nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm nomodeset nvme_load=yes loglevel=3 --
    initrd /live/initrd
}
EOF

    VER_SUFFIX=""
    if [ -n "$PULSAR_VERSION" ]; then
        VER_SUFFIX="-${PULSAR_VERSION}"
    fi

    if $WITH_NVIDIA; then
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}-refind${VER_SUFFIX}-nvidia.iso"
    else
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}-refind${VER_SUFFIX}.iso"
    fi
    echo "💿 Generando archivo ISO rEFInd en / Generating rEFInd ISO file at: $ISO_OUTPUT..."
    # Add a hybrid MBR so the ISO is a valid disk image: balenaEtcher requires it
    # and direct USB flashing (dd) needs it for UEFI to find the GPT ESP partition.
    # grub-mkrescue uses boot_hybrid.img; fall back to the syslinux isohdpfx.bin.
    # Añadir un MBR híbrido para que la ISO sea una imagen de disco válida: lo exige
    # balenaEtcher y el volcado con dd (UEFI arranca desde la partición GPT ESP).
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
    if [ -z "$HYBRID_MBR" ]; then
        echo "❌ Error: No se encontró un template MBR híbrido (boot_hybrid.img de GRUB o isohdpfx.bin de syslinux). Instala 'grub' o 'syslinux' en el host."
        exit 1
    fi
    $SUDO xorriso -as mkisofs \
      -o "$ISO_OUTPUT" \
      -J -R -V "PULSAR_ISO" \
      -isohybrid-mbr "$HYBRID_MBR" \
      -eltorito-alt-boot \
      -e "boot/efi.img" \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$ISO_STAGING"
fi

BUILD_END_TS=$(date '+%Y-%m-%d %H:%M:%S')
BUILD_END_EPOCH=$(date +%s)
ELAPSED=$((BUILD_END_EPOCH - BUILD_START_EPOCH))
ELAPSED_FMT=$(printf '%02dh %02dm %02ds' $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))

echo "=============================================================================="
echo "🎉 Pulsar OS ISO ($BOOTLOADER) generated successfully!"
echo "📍 Location: $ISO_OUTPUT"
echo "🕐 Build started at: $BUILD_START_TS"
echo "🕓 Build finished at: $BUILD_END_TS"
echo "⏱️  Total build time: $ELAPSED_FMT"
echo "=============================================================================="
