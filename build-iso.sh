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

# Guardar argumentos originales para la auto-elevación antes de ser consumidos por shift
ORIGINAL_ARGS=("$@")

# ==============================================================================
# Parse Arguments / Parámetros
# ==============================================================================
CLEAN_BASE=false
USE_LOCAL_DEBS=false
BOOTLOADER="grub" # Default bootloader is GRUB / El cargador por defecto es GRUB
BRANCH="stable"
WITH_NVIDIA=false
DISTRO="debian"   # Distribution: debian or arch / Distribución: debian o arch

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-base)
            CLEAN_BASE=true
            shift
            ;;
        --local)
            USE_LOCAL_DEBS=true
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

# ==============================================================================
# Detect distribution type from branch suffix or explicit flag
# ==============================================================================
if [ "$DISTRO" = "arch" ]; then
    echo "🏗️  Modo Arch Linux activado / Arch Linux mode enabled"
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

# IMPORTANT: Check Debian archive keyring on non-Debian host distros (like Ubuntu/Mint)
# IMPORTANTE: Comprobar el llavero de Debian en hosts Ubuntu/Debian no oficiales
if [ "$DISTRO" != "arch" ] && [ ! -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
    MISSING_PACKAGES+=("debian-archive-keyring")
fi

# Install dependencies if they are missing / Instalar dependencias si faltan
if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    echo "⚠️ Se ha detectado que faltan dependencias esenciales en el host: ${MISSING_PACKAGES[*]}"
    echo "Estas herramientas son requeridas para la compilación de Pulsar OS ($BOOTLOADER)."
    
    # SAFETY GUARD: never touch the host package manager by default.
    # The ISO build runs on the user's own machine (often Arch), and host-level
    # pacman/apt operations (especially 'pacman -Sy' partial upgrades) can break it.
    # Only auto-install when explicitly requested with --install-host-deps.
    # GUARDIA DE SEGURIDAD: por defecto nunca se toca el gestor de paquetes del host.
    if [ "$ALLOW_HOST_INSTALL" != "true" ]; then
        echo "❌ Dependencias del host faltantes. NO se auto-instalarán para proteger tu sistema."
        echo "   Instala manualmente los paquetes que falten (p. ej. pacman -S ${MISSING_PACKAGES[*]})"
        echo "   o repite el comando con la variable ALLOW_HOST_INSTALL=true para autorizar la instalación."
        exit 1
    fi
    
    # Auto-approve if in non-interactive environment (CI, pipeline, no TTY stdin)
    # Aprobación automática si estamos en un entorno no interactivo (CI, pipeline, sin TTY stdin)
    auto_install=false
    if [ "$GITHUB_ACTIONS" = "true" ] || [ ! -t 0 ]; then
        auto_install=true
    else
        read -p "¿Deseas instalar las dependencias faltantes ahora? (s/n): " confirm
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
            echo "❌ Error: No se detectó un gestor de paquetes soportado (apt o pacman)."
            exit 1
        fi

        packages_to_install=()
        for item in "${MISSING_PACKAGES[@]}"; do
            case "$item" in
                mmdebstrap|fakeroot|rsync|jq|curl|unzip|wget|xorriso|imagemagick|psmisc|mtools|debian-archive-keyring|sassc)
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
            echo "📥 Instalando dependencias en el host usando $pkg_manager..."
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
                    echo "📥 Instalando dependencias oficiales usando pacman..."
                    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
                        pkexec pacman -Sy --noconfirm "${pacman_official[@]}"
                    else
                        sudo pacman -Sy --noconfirm "${pacman_official[@]}"
                    fi
                fi

                if [ ${#aur_packages[@]} -gt 0 ]; then
                    echo "⚠️ Los siguientes paquetes son del repositorio AUR y no están en los repos oficiales:"
                    echo "   ${aur_packages[*]}"
                    
                    # Try to locate an AUR helper
                    aur_helper=""
                    if command -v yay >/dev/null 2>&1; then
                        aur_helper="yay"
                    elif command -v paru >/dev/null 2>&1; then
                        aur_helper="paru"
                    fi

                    if [ -n "$aur_helper" ]; then
                        echo "🚀 Se ha detectado el ayudante de AUR: $aur_helper. Instalando..."
                        # Run AUR helper as the original non-root user if SUDO_USER is defined
                        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                            sudo -u "$SUDO_USER" "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        else
                            "$aur_helper" -S --noconfirm "${aur_packages[@]}"
                        fi
                    else
                        echo "❌ No se detectó ningún asistente de AUR (como yay o paru)."
                        echo "Por favor, instala estos paquetes manualmente antes de continuar:"
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
            echo "✅ Dependencias instaladas con éxito."
        else
            echo "✅ No hay paquetes que instalar para tu plataforma."
        fi
    else
        echo "❌ Error: No se pueden cumplir los requisitos del host. Saliendo..."
        exit 1
    fi
fi

# ==============================================================================
# Helper: Auto-Elevate to Root
# Ayudante: Auto-elevación a privilegios de superusuario
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "🔐 Este script requiere privilegios de superusuario para ejecutarse."
    echo "Re-ejecutando con pkexec..."
    if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        exec pkexec "$0" "${ORIGINAL_ARGS[@]}"
    else
        exec sudo "$0" "${ORIGINAL_ARGS[@]}"
    fi
fi

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

# Pacman cache dir in home (not in /var/cache/pacman on root partition)
PACMAN_CACHE_DIR="$ORIGINAL_HOME/.cache/pacman"
mkdir -p "$PACMAN_CACHE_DIR"
if [ "$EUID" -eq 0 ] && [ -n "$ORIGINAL_USER" ]; then
    chown -R "$ORIGINAL_USER":"$ORIGINAL_USER" "$ORIGINAL_HOME/.cache" 2>/dev/null || true
fi

if $WITH_NVIDIA; then
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-$DISTRO-nvidia"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-$DISTRO-nvidia"
else
    ROOTFS_BASE="$BUILD_DIR/rootfs-base-$BRANCH-$DISTRO"
    ROOTFS_TARGET="$BUILD_DIR/rootfs-target-$BRANCH-$DISTRO"
fi

# Select package list based on distro
if [ "$DISTRO" = "arch" ]; then
    PACKAGE_LIST_FILE="$ISO_DIR/configs/base-arch.list"
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

# Preventative cleanup function to ensure filesystems are unmounted on interruption
# Función de limpieza preventiva para asegurar desmontajes en caso de interrupción
cleanup() {
    echo "🧹 Finalizando y liberando recursos montados en el chroot..."
    $SUDO umount -l "$ROOTFS_TARGET/proc" 2>/dev/null || true
    $SUDO umount -l "$ROOTFS_TARGET/sys" 2>/dev/null || true
    $SUDO umount -l "$ROOTFS_TARGET/dev/pts" 2>/dev/null || true
    $SUDO umount -l "$ROOTFS_TARGET/dev" 2>/dev/null || true
    $SUDO umount -l "$ROOTFS_TARGET/var/cache/pacman/pkg" 2>/dev/null || true
    
    # Restore original DNS config in target if backup exists
    # Restaurar DNS original en el target si quedó copia
    if [ -f "$ROOTFS_TARGET/etc/resolv.conf.bak" ]; then
        $SUDO mv "$ROOTFS_TARGET/etc/resolv.conf.bak" "$ROOTFS_TARGET/etc/resolv.conf" 2>/dev/null || true
    fi
}

# Preflight: release any leftover mounts from previous interrupted builds.
# This runs once at startup so a fresh build never fails on stale mounts.
# Prelanzamiento: libera montajes residuales de builds interrumpidos.
# Se ejecuta una vez al inicio para que un build nuevo nunca falle por montajes viejos.
preflight_cleanup() {
    echo "🔍 Comprobando montajes residuales de builds anteriores..."
    # Unmount anything mounted under the build directory (leftover chroot mounts)
    # Desmontar todo lo montado bajo el directorio de build (montajes chroot residuales)
    awk '$2 ~ "^'"$BUILD_DIR"'/" || $2 == "'"$BUILD_DIR"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        echo "   Desmontando residual: $mp"
        $SUDO umount -l "$mp" 2>/dev/null || true
    done
    # Free known helper mount points (e.g. ISO verification leftovers)
    # Liberar puntos de montaje auxiliares conocidos (p.ej. sobras de verificación ISO)
    for mp in /tmp/iso-mnt /tmp/pulsar-verify /tmp/pulsar-iso; do
        if mountpoint -q "$mp" 2>/dev/null; then
            echo "   Desmontando residual: $mp"
            $SUDO umount -l "$mp" 2>/dev/null || true
        fi
    done
    echo "✅ Comprobación de montajes residuales completada."
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
    echo "⚠️ Caché base incompleta o corrupta detectada. Limpiando para regenerar..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
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
        echo "🔄 No se encontró pulsaros-base.list en la caché. Regenerando base..."
        base_list_changed=true
    else
        cached_list=$(cat "$ROOTFS_BASE/etc/pulsaros-base.list")
        if [ "$current_list" != "$cached_list" ]; then
            echo "🔄 Se ha detectado un cambio en la lista de paquetes requerida con respecto a la base en caché. Regenerando base..."
            base_list_changed=true
        fi
    fi
fi

if $CLEAN_BASE || [ "$base_list_changed" = true ]; then
    echo "🚨 Limpieza total de la caché base solicitada o cambio de lista de paquetes detectado..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    mkdir -p "$BUILD_DIR"
    
    if [ ! -f "$PACKAGE_LIST_FILE" ]; then
        echo "❌ Error: No se encontró el archivo de paquetes base en: $PACKAGE_LIST_FILE"
        exit 1
    fi
    
    if [ "$DISTRO" = "arch" ]; then
        echo "--- 📥 Creando Arch Linux Base (pacstrap) ---"
        PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ' ')
        
        # Bootstrap Arch Linux using pacstrap
        # Note: without -c, package cache goes to target (in home) instead of host's /var/cache/pacman (root)
        mkdir -p "$ROOTFS_BASE"
        $SUDO pacstrap -c -K "$ROOTFS_BASE" $PACKAGE_LIST
        
        # Save the actually used package list in the base cache for future diffs
        grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | $SUDO tee "$ROOTFS_BASE/etc/pulsaros-base.list" > /dev/null
        
        echo "✅ Bootstrap de Arch base completado en: $ROOTFS_BASE"
    else
        echo "--- 📥 Creando Debian Base Limpio (mmdebstrap) ---"
        
        if $WITH_NVIDIA; then
            echo "💚 Incluyendo controladores de hardware propietarios (NVIDIA, Broadcom STA, DKMS, Headers) en la instalación..."
            PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
        else
            echo "💙 Excluyendo controladores propietarios (NVIDIA, Broadcom STA, DKMS, Headers) de la instalación..."
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
        
        echo "✅ Bootstrap de Debian base completado en: $ROOTFS_BASE"
    fi
else
    echo "✨ Base virgen detectada en caché. Saltando bootstrap."
fi

# ==============================================================================
# PHASE 3: Clone clean base for working target / FASE 3: Clonar base limpia
# ==============================================================================

if [ "$DISTRO" = "arch" ]; then
    echo "--- 🔄 Clonando Arch base en el directorio de trabajo (target) ---"
else
    echo "--- 🔄 Clonando Debian base en el directorio de trabajo (target) ---"
fi
cleanup
$SUDO rm -rf "$ROOTFS_TARGET"
mkdir -p "$ROOTFS_TARGET"

# Sync keeping special attributes / Sincronización manteniendo atributos especiales
$SUDO rsync -aHAXx --delete "$ROOTFS_BASE/" "$ROOTFS_TARGET/"

# ==============================================================================
# PHASE 4: Mount virtual filesystems and network / FASE 4: Montar directorios y red
# ==============================================================================

echo "⚙️ Configurando montajes virtuales y DNS..."
$SUDO mount -t proc proc "$ROOTFS_TARGET/proc"
$SUDO mount -t sysfs sys "$ROOTFS_TARGET/sys"
$SUDO mount --bind /dev "$ROOTFS_TARGET/dev"
$SUDO mount --bind /dev/pts "$ROOTFS_TARGET/dev/pts"

# Bind mount pacman cache dir in home (not root partition) if on Arch
if [ "$DISTRO" = "arch" ]; then
    $SUDO mount --bind "$PACMAN_CACHE_DIR" "$ROOTFS_TARGET/var/cache/pacman/pkg"
fi

# Ensure working DNS in chroot / Asegurar DNS funcional en el chroot
if [ -f "$ROOTFS_TARGET/etc/resolv.conf" ]; then
    $SUDO cp "$ROOTFS_TARGET/etc/resolv.conf" "$ROOTFS_TARGET/etc/resolv.conf.bak"
fi
echo "nameserver 8.8.8.8" | $SUDO tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

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
    echo "--- 🐧 Configurando repositorios Arch Linux (Inled) ---"

    # Copy the Inled keyring to chroot
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg"

    # Configure Inled pacman repository
    $SUDO tee -a "$ROOTFS_TARGET/etc/pacman.conf" > /dev/null <<EOF

[inled]
SigLevel = PackageRequired
Server = https://apt.inled.es/arch/
EOF

    # Disable CheckSpace: inside chroot, pacman reads host's /proc/self/mountinfo
    # and can't find chroot root as a mountpoint, causing false 'not enough space' errors.
    # We must comment it out in the [options] section rather than appending a 'CheckSpace = false'
    # which is not recognized as a valid directive under the [inled] section.
    $SUDO sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' "$ROOTFS_TARGET/etc/pacman.conf"

    # Bootstrap packages into target
    if [ "$BOOTLOADER" = "grub" ]; then
        BOOTLOADER_PKGS="grub"
    else
        BOOTLOADER_PKGS="refind efibootmgr"
    fi

    if $USE_LOCAL_DEBS; then
        echo "--- 🛠️ MODO DESARROLLO LOCAL: Instalando paquetes Arch locales ---"
        pkg_dir_source="$ISO_DIR/../PKG/arch"
        if [ ! -d "$pkg_dir_source" ]; then
            pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG/arch"
        fi

        if [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
            echo "🔨 Compilando todos los paquetes locales de forma fresca..."
            chmod +x "$pkg_dir_source/package-and-deploy.sh" 2>/dev/null || true
            # Run as the original non-root user since makepkg cannot run as root
            if [ -n "$ORIGINAL_USER" ] && [ "$ORIGINAL_USER" != "root" ]; then
                run_as_user bash -c "cd '$pkg_dir_source' && ./package-and-deploy.sh all"
            else
                (cd "$pkg_dir_source" && ./package-and-deploy.sh all)
            fi
        else
            echo "⚠️ Advertencia: No se encontró el script de empaquetado en $pkg_dir_source/package-and-deploy.sh. Se intentará usar paquetes pre-existentes."
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
            echo "❌ Error: No se encontraron paquetes Arch locales en ninguna de las rutas de búsqueda:"
            for dir in "${POSSIBLE_DIRS[@]}"; do echo "   - $dir"; done
            echo "Ejecuta primero el empaquetador en la carpeta PKG/arch/."
            exit 1
        fi

        # Compile and gather AUR dependencies on the host, saving them directly into LOCAL_PKGS_DIR
        # so they are copied and installed inside the chroot
        AUR_DEPS=("calamares" "pamtester" "xremap-gnome-bin")
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
                    echo "✅ Dependencia AUR ya compilada: $dep"
                    continue
                fi
                
                echo "🔨 Compilando dependencia AUR: $dep..."
                BUILD_TEMP_DIR="/tmp/pulsaros-aur-$dep"
                $SUDO rm -rf "$BUILD_TEMP_DIR"
                mkdir -p "$BUILD_TEMP_DIR"
                $SUDO chown "$ORIGINAL_USER":"$ORIGINAL_USER" "$BUILD_TEMP_DIR"
                
                # Download PKGBUILD using helper
                run_as_user bash -c "cd '$BUILD_TEMP_DIR' && $aur_helper -G '$dep'"
                
                dep_dir=$(find "$BUILD_TEMP_DIR" -maxdepth 2 -type d -name "$dep")
                if [ -n "$dep_dir" ]; then
                    # Build package and save to LOCAL_PKGS_DIR
                    # We run as ORIGINAL_USER since makepkg cannot run as root.
                    run_as_user bash -c "cd '$dep_dir' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -sf --noconfirm"
                    echo "✅ Dependencia AUR $dep compilada con éxito."
                else
                    echo "❌ Error: No se pudo obtener el PKGBUILD para $dep."
                    exit 1
                fi
                $SUDO rm -rf "$BUILD_TEMP_DIR"
            done
        fi

        # Compile spotlight-gtk local package if it exists on the host
        SPOTLIGHT_REPO_DIR="/home/jaime/Documentos/spotlight-gtk"
        if [ -d "$SPOTLIGHT_REPO_DIR" ] && [ -f "$SPOTLIGHT_REPO_DIR/PKGBUILD" ]; then
            if ! ls "$LOCAL_PKGS_DIR"/spotlight-gtk-*.pkg.tar.zst >/dev/null 2>&1; then
                echo "🔨 Compilando spotlight-gtk localmente..."
                run_as_user bash -c "cd '$SPOTLIGHT_REPO_DIR' && PKGDEST='$LOCAL_PKGS_DIR' makepkg -sf --noconfirm"
                echo "✅ spotlight-gtk compilado con éxito."
            fi
        fi

        echo "📂 Usando paquetes locales desde: $LOCAL_PKGS_DIR"
        $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
        $SUDO cp "$LOCAL_PKGS_DIR"/*.pkg.tar.zst "$ROOTFS_TARGET/tmp/packages/"
        if [ "$BOOTLOADER" = "grub" ]; then
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-refind-*.pkg.tar.zst
        else
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-grub-*.pkg.tar.zst
        fi

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e

            # Init pacman keyring
            mkdir -p /etc/pacman.d/gnupg
            chmod 700 /etc/pacman.d/gnupg

            # Write mirrorlist
            echo 'Server = $MIRROR' > /etc/pacman.d/mirrorlist

            # Init and populate keyring
            pacman-key --init
            pacman-key --populate archlinux

            # Import and sign Inled repo key from bundled file (before syncing Inled repo)
            pacman-key --add /usr/share/keyrings/inled-archive-keyring.gpg
            pacman-key --lsign-key 89F828A9675B63CD0077CE9965AA57CF36E2018F

            # Sync databases and install keyring
            pacman -Sy --noconfirm archlinux-keyring

            # Install local packages (using -U) and pull dependencies
            pacman -U --noconfirm --overwrite '*' /tmp/packages/*.pkg.tar.zst

            # Install remaining dependencies and packages
            pacman -S --noconfirm --overwrite '*' \
                $BOOTLOADER_PKGS \
                droidtux \
                macboat \
                appinstall \
                seafari \
                spotlight-gtk
        "
        $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        echo "✅ Paquetes locales de Arch instalados con éxito."
    else
        echo "--- 🌐 MODO PRODUCCIÓN: Instalando paquetes desde repositorio Arch (Inled) ---"
        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e

            # Init pacman keyring
            mkdir -p /etc/pacman.d/gnupg
            chmod 700 /etc/pacman.d/gnupg

            # Write mirrorlist
            echo 'Server = $MIRROR' > /etc/pacman.d/mirrorlist

            # Init and populate keyring
            pacman-key --init
            pacman-key --populate archlinux

            # Import and sign Inled repo key from bundled file (before syncing Inled repo)
            pacman-key --add /usr/share/keyrings/inled-archive-keyring.gpg
            pacman-key --lsign-key 89F828A9675B63CD0077CE9965AA57CF36E2018F

            # Sync databases and install keyring
            pacman -Sy --noconfirm archlinux-keyring

            # Install Pulsar OS packages and bootloader
            pacman -S --noconfirm --overwrite '*' \
                $BOOTLOADER_PKGS \
                pulsaros-branding \
                pulsaros-theme \
                pulsaros-gnome \
                pulsaros-global-menu \
                pulsaros-spotlight-launcher \
                pulsaros-sddm \
                pulsaros-plymouth \
                pulsaros-$BOOTLOADER \
                pulsaros-calamares \
                pulsaros-essential \
                pulsaros-welcome \
                pulsaros-recovery \
                pulsaros-bootsound \
                gnome-macos-remap-wayland \
                droidtux \
                macboat \
                appinstall \
                seafari \
                spotlight-gtk
        "
        echo "✅ Paquetes de Arch instalados desde el repositorio Inled."
    fi
else
    # ==========================================================================
    # DEBIAN PATH (original)
    # ==========================================================================
    echo "--- 🌐 Configurando repositorios APT (Debian Contrib/Backports e Inled) ---"
    $SUDO sed -i "s/$DEBIAN_VERSION main/$DEBIAN_VERSION main contrib non-free non-free-firmware/g" "$ROOTFS_TARGET/etc/apt/sources.list"
    if ! grep -q "${DEBIAN_VERSION}-backports" "$ROOTFS_TARGET/etc/apt/sources.list"; then
        echo "deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware" | $SUDO tee -a "$ROOTFS_TARGET/etc/apt/sources.list" > /dev/null
    fi

    # Copy the bundled Inled APT GPG keyring directly to the chroot target
    echo "🔑 Copiando el llavero GPG de Inled pre-empaquetado..."
    $SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
    $SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg"

    echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es $BRANCH main" | \
        $SUDO tee "$ROOTFS_TARGET/etc/apt/sources.list.d/inled.list" > /dev/null

    # Create temporary dpkg-diverts to intercept DroidTux's and AppInstall's keyring setup
    echo "⚙️ Configurando desvíos de dpkg temporales para DroidTux y AppInstall..."
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

    if $USE_LOCAL_DEBS; then
        echo "--- 🛠️ MODO DESARROLLO LOCAL: Instalando paquetes .deb locales ---"
        pkg_dir_source="$ISO_DIR/../PKG"
        if [ ! -d "$pkg_dir_source" ]; then
            pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG"
        fi

        if [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
            echo "🔨 Compilando todos los paquetes locales de forma fresca para la rama $BRANCH..."
            chmod +x "$pkg_dir_source/package-and-deploy.sh" 2>/dev/null || true
            (cd "$pkg_dir_source" && ./package-and-deploy.sh all --branch "$BRANCH")
        else
            echo "⚠️ Advertencia: No se encontró el script de empaquetado en $pkg_dir_source/package-and-deploy.sh. Se intentará usar debs pre-existentes."
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
            echo "❌ Error: No se encontraron paquetes .deb locales en ninguna de las rutas de búsqueda:"
            for dir in "${POSSIBLE_DIRS[@]}"; do echo "   - $dir"; done
            echo "Ejecuta primero el empaquetador en la carpeta PKG/."
            exit 1
        fi

        echo "📂 Usando paquetes locales desde: $LOCAL_DEBS_DIR"
        $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
        $SUDO cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"
        if [ "$BOOTLOADER" = "grub" ]; then
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-refind_*.deb
        else
            $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-grub_*.deb
        fi

        if [ "$BOOTLOADER" = "grub" ]; then
            BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin"
        else
            BOOTLOADER_PKGS="refind efibootmgr"
        fi

        $SUDO tee "$ROOTFS_TARGET/etc/apt/preferences.d/local-pulsar" > /dev/null <<EOF
Package: pulsaros-* gnome-macos-remap-wayland
Pin: release *
Pin-Priority: -1
EOF

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export DEBIAN_FRONTEND=noninteractive
            echo 'refind refind/install_to_esp boolean false' | debconf-set-selections
            apt-get update
            yes | apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
            yes | apt-get install -y --no-install-recommends $BOOTLOADER_PKGS
            yes | apt-get install -y \
                /tmp/packages/*.deb \
                droidtux \
                macboat \
                appinstall \
                seafari \
                spotlight-python
            apt-get clean
        "
        $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
        $SUDO rm -f "$ROOTFS_TARGET/etc/apt/preferences.d/local-pulsar"
        echo "✅ Paquetes locales e instalados de forma cruzada con éxito."
    else
        echo "--- 🌐 MODO PRODUCCIÓN: Instalando paquetes desde repositorio APT ---"
        if [ "$BOOTLOADER" = "grub" ]; then
            BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin"
        else
            BOOTLOADER_PKGS="refind efibootmgr"
        fi

        $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
            set -e
            export DEBIAN_FRONTEND=noninteractive
            echo 'refind refind/install_to_esp boolean false' | debconf-set-selections
            apt-get update
            yes | apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
            yes | apt-get install -y --no-install-recommends \
                $BOOTLOADER_PKGS \
                pulsaros-branding \
                pulsaros-theme \
                pulsaros-gnome \
                pulsaros-global-menu \
                pulsaros-spotlight-launcher \
                pulsaros-sddm \
                pulsaros-plymouth \
                pulsaros-\$BOOTLOADER \
                pulsaros-calamares \
                pulsaros-essential \
                pulsaros-welcome \
                pulsaros-recovery \
                pulsaros-bootsound \
                gnome-macos-remap-wayland \
                droidtux \
                macboat \
                appinstall \
                seafari \
                spotlight-python
            apt-get clean
        "
    fi

    # Clean up temporary DroidTux and AppInstall mocks and restore dpkg-diverts
    echo "🧹 Limpiando mocks y desvíos de dpkg de DroidTux y AppInstall..."
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/curl"
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/wget"
    $SUDO rm -f "$ROOTFS_TARGET/usr/bin/gpg"

    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        dpkg-divert --remove --rename /usr/bin/curl
        dpkg-divert --remove --rename /usr/bin/wget
        dpkg-divert --remove --rename /usr/bin/gpg
    "
fi

# Dynamically adjust Calamares configuration inside chroot based on selected bootloader
if [ "$BOOTLOADER" = "refind" ]; then
    echo "⚙️ Configurando Calamares para rEFInd (removiendo módulos de GRUB)..."
    if [ -f "$ROOTFS_TARGET/etc/calamares/settings.conf" ]; then
        $SUDO sed -i 's/- grubcfg/- shellprocess@refind/' "$ROOTFS_TARGET/etc/calamares/settings.conf"
        $SUDO sed -i '/- bootloader/d' "$ROOTFS_TARGET/etc/calamares/settings.conf"
    fi
else
    echo "⚙️ Calamares configurado para GRUB (módulos por defecto)."
fi

# ==============================================================================
# PHASE 5.5: Configure System Apps (Flatpak and External Winboat)
# FASE 5.5: Configuración de Aplicaciones del Sistema (Flatpak y Winboat)
# ==============================================================================

# Configure spotlight icon / Configurar el icono de spotlight a 'view-app-grid'
echo "⚙️ Personalizando lanzador de Spotlight..."
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    set -e
    if [ -f /usr/share/applications/spotlight-python.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-python.desktop
    elif [ -f /usr/share/applications/spotlight-gtk.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-gtk.desktop
    fi
"

if [ "$DISTRO" = "debian" ]; then
    # Download external winboat dependencies on host and copy to chroot
    echo "📥 Descargando dependencias externas (Winboat) en el host..."
    wget -q --timeout=15 --tries=3 -O "$BUILD_DIR/winboat.deb" https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-amd64.deb
    $SUDO cp "$BUILD_DIR/winboat.deb" "$ROOTFS_TARGET/tmp/winboat.deb"
    rm -f "$BUILD_DIR/winboat.deb"

    echo "📥 Instalando Winboat..."
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        apt-get install -y /tmp/winboat.deb
        rm -f /tmp/winboat.deb
    "
fi

# English: Configure static autologin for SDDM live user inside the rootfs (using GNOME Wayland)
# Español: Configurar autologin estático para el usuario live de SDDM en el rootfs (usando GNOME Wayland)
echo "⚙️ Configurando autologin estático para la sesión en vivo (Wayland)..."
$SUDO mkdir -p "$ROOTFS_TARGET/etc/sddm.conf.d"
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf" > /dev/null
[Autologin]
User=live
Session=gnome
EOF
$SUDO chmod 644 "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf"

# ==============================================================================
# PHASE 6: Final Tasks (Initramfs regeneration and cleanup)
# FASE 6: Tareas Finales del Sistema (Generación de Kernel y Limpieza)
# ==============================================================================

if [ "$DISTRO" = "arch" ]; then
    echo "--- 🔄 Regenerando initramfs con mkinitcpio ---"
    # Create mkinitcpio hook configuration for live booting
    $SUDO mkdir -p "$ROOTFS_TARGET/etc/mkinitcpio.conf.d"
    echo 'HOOKS=(base udev modconf kms archiso archiso_loop_mnt block filesystems keyboard)' | $SUDO tee "$ROOTFS_TARGET/etc/mkinitcpio.conf.d/archiso.conf" > /dev/null
    # Set the GRUB menu entry label to Pulsar OS instead of the archiso default "Arch"
    if [ -f "$ROOTFS_TARGET/etc/default/grub" ]; then
        $SUDO sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Pulsar OS"/' "$ROOTFS_TARGET/etc/default/grub"
    fi
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        mkinitcpio -P
    "
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

# ==============================================================================
# PHASE 7: Packaging and Live ISO Generation
# FASE 7: Creación de la Imagen Live ISO
# ==============================================================================
echo "--- 💿 Creando la Imagen Live ISO de Pulsar OS / Creating Pulsar OS Live ISO ---"

ISO_STAGING="$BUILD_DIR/iso-staging"
$SUDO rm -rf "$ISO_STAGING"
mkdir -p "$ISO_STAGING/live"
mkdir -p "$ISO_STAGING/boot/grub"

# 0. Unmount virtual filesystems prior to packaging / Desmontar sistemas de archivos virtuales antes de empaquetar
echo "🧹 Desmontando sistemas de archivos virtuales en el target... / Unmounting virtual filesystems in target..."
$SUDO umount -l "$ROOTFS_TARGET/proc" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/sys" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/dev/pts" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/dev" 2>/dev/null || true
$SUDO umount -l "$ROOTFS_TARGET/var/cache/pacman/pkg" 2>/dev/null || true

# 1. Compress rootfs into SquashFS / Comprimir el rootfs en SquashFS
echo "📦 Comprimiendo rootfs en SquashFS (esto puede tardar unos minutos)... / Compressing rootfs into SquashFS..."
# Exclude dynamic/temp directories and virtual filesystems to save space and prevent errors
# Excluimos directorios dinámicos, temporales y sistemas de archivos virtuales para ahorrar espacio y evitar errores
    if [ "$DISTRO" = "arch" ]; then
        SQUASHFS_OUT="$ISO_STAGING/live/x86_64/airootfs.sfs"
        $SUDO mkdir -p "$ISO_STAGING/live/x86_64"
    else
        SQUASHFS_OUT="$ISO_STAGING/live/filesystem.squashfs"
    fi
    $SUDO mksquashfs "$ROOTFS_TARGET" "$SQUASHFS_OUT" \
        -noappend \
        -comp xz \
        -e proc/* \
        -e sys/* \
        -e dev/* \
        -e run/* \
        -e tmp/* \
        -e var/tmp/* \
        -e var/log/* \
        -e root/.bash_history

# 2. Copy Kernel and Initrd to ISO staging / Copiar Kernel e Initrd al directorio de la ISO
echo "🐧 Copiando Kernel e Initrd... / Copying Kernel and Initrd..."
if [ "$DISTRO" = "arch" ]; then
    KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
    INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -n 1)
else
    KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
    INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initrd.img-* 2>/dev/null | head -n 1)
fi

if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
    echo "❌ Error: No se encontró kernel o initrd en el chroot target. / Error: Kernel or initrd not found in target chroot."
    exit 1
fi

$SUDO cp "$KERNEL_FILE" "$ISO_STAGING/live/vmlinuz"
$SUDO cp "$INITRD_FILE" "$ISO_STAGING/live/initrd"

if [ "$BOOTLOADER" = "grub" ]; then
    # --------------------------------------------------------------------------
    # GRUB BOOTLOADER PACKAGING
    # --------------------------------------------------------------------------
    echo "⚙️ Configurando GRUB para la ISO... / Configuring GRUB for ISO..."
    $SUDO mkdir -p "$ISO_STAGING/boot/grub"
    
    # Copy the custom GRUB theme to the ISO staging directory / Copiar el tema de GRUB personalizado
    if [ -d "$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window" ]; then
        echo "🎨 Copiando tema de GRUB de Pulsar OS a la ISO staging..."
        $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes"
        $SUDO cp -r "$ROOTFS_TARGET/boot/grub/themes/Particle-circle-window" "$ISO_STAGING/boot/grub/themes/"
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
    
    if [ "$DISTRO" = "arch" ]; then
        KERNEL_PARAMS="archisobasedir=live archisolabel=PULSAR_ISO quiet splash loglevel=3 --"
    else
        KERNEL_PARAMS="boot=live components username=live autologin quiet splash loglevel=3 noprompt --"
    fi

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

loadfont /boot/grub/themes/Particle-circle-window/terminus-12.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-14.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-16.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-18.pf2
loadfont /boot/grub/themes/Particle-circle-window/unifont-16.pf2
set theme=/boot/grub/themes/Particle-circle-window/theme.txt

menuentry "Pulsar OS Live (RAM)" {
    linux /live/vmlinuz $KERNEL_PARAMS
    initrd /live/initrd
}
EOF

    if $WITH_NVIDIA; then
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}-nvidia.iso"
    else
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-${DISTRO}.iso"
    fi
    # Create a temporary xorriso wrapper to force -iso-level 3
    # which allows files larger than 4GB (ISO 9660 Level 3 multi-extents)
    # We also set the volume label to PULSAR_ISO so the archiso hook can locate it
    WRAPPER_PATH="/tmp/xorriso-wrapper"
    echo '#!/bin/bash' > "$WRAPPER_PATH"
    echo 'exec xorriso "$@" -iso-level 3 -volid PULSAR_ISO' >> "$WRAPPER_PATH"
    chmod +x "$WRAPPER_PATH"

    echo "💿 Generando archivo ISO GRUB en / Generating GRUB ISO file at: $ISO_OUTPUT..."
    $SUDO grub-mkrescue --xorriso="$WRAPPER_PATH" -o "$ISO_OUTPUT" "$ISO_STAGING"
    rm -f "$WRAPPER_PATH"

else
    # --------------------------------------------------------------------------
    # rEFInd BOOTLOADER PACKAGING
    # --------------------------------------------------------------------------
    echo "💿 Creando imagen EFI bootable con rEFInd... / Creating bootable EFI image with rEFInd..."
    $SUDO mkdir -p "$ISO_STAGING/boot"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT"
    EFI_IMG="$ISO_STAGING/boot/efi.img"

    # Create a 150MB empty file and format it as FAT16 (eliminates FAT32 cluster warnings and has space for kernel/initrd)
    # Crear un archivo vacío de 150MB y formatearlo en FAT16 (elimina avisos de clúster de FAT32 y tiene espacio para kernel/initrd)
    $SUDO dd if=/dev/zero of="$EFI_IMG" bs=1M count=150 2>/dev/null
    $SUDO mkfs.vfat -F 16 "$EFI_IMG" >/dev/null

    # Create temporary refind.conf for the ISO boot (full config with theme — goes inside efi.img)
    cat <<EOF > "$BUILD_DIR/refind.conf"
timeout 10
enable_mouse
mouse_speed 4
mouse_size 16
resolution 1024 768
default_selection "+,pulsaros,Pulsar OS Live"
#showtools about,reboot,shutdown,firmware,hidden_tags
include themes/rEFInd-Regular-Dark/theme.conf

menuentry "Pulsar OS Live" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "boot=live components username=live autologin quiet splash loglevel=3 noprompt --"
}
EOF

    # Minimal refind.conf for the ISO root (no showtools, no theme — avoids duplicate tool buttons
    # when rEFInd scans both ISO9660 and FAT efi.img filesystems)
    cat <<EOF > "$BUILD_DIR/refind-minimal.conf"
timeout 10
resolution 1024 768
default_selection "+,pulsaros,Pulsar OS Live"

menuentry "Pulsar OS Live" {
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "boot=live components username=live autologin quiet splash loglevel=3 noprompt --"
}
EOF

    # Get the theme (copy local if exists, else clone from GitHub)
    echo "🎨 Obteniendo tema macOS de rEFInd..."
    $SUDO rm -rf "$BUILD_DIR/refind-mac-theme"
    if [ -d "$ISO_DIR/../refind" ]; then
        echo "📂 Copiando tema local desde: $ISO_DIR/../refind"
        $SUDO cp -r "$ISO_DIR/../refind" "$BUILD_DIR/refind-mac-theme"
        $SUDO rm -rf "$BUILD_DIR/refind-mac-theme/.git"
    else
        echo "🌐 Descargando tema desde GitHub..."
        $SUDO git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --depth=1 "https://github.com/Inled-Pulsar-OS/refind-mac-theme" "$BUILD_DIR/refind-mac-theme"
    fi
    $SUDO sed -i '/#MENUENTRIES/q' "$BUILD_DIR/refind-mac-theme/theme.conf"

    # 1. Populate the ISO root /EFI/BOOT folder for direct UEFI boot (resolves QEMU boot problems)
    # NOTE: refind.conf, icons and theme go ONLY inside efi.img to avoid rEFInd
    # processing showtools from two filesystems and duplicating tool buttons.
    # Solo el bootloader, driver, kernel e initrd van en la raíz ISO.
    echo "📂 Copiando archivos de rEFInd, kernel e initrd a la raíz de la ISO staging..."
    $SUDO cp "$ROOTFS_TARGET/usr/share/refind/refind/refind_x64.efi" "$ISO_STAGING/EFI/BOOT/bootx64.efi"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT/drivers_x64"
    $SUDO cp "$ROOTFS_TARGET/usr/share/refind/refind/drivers_x64/"*iso9660*.efi "$ISO_STAGING/EFI/BOOT/drivers_x64/" 2>/dev/null || true
    $SUDO cp "$BUILD_DIR/refind-minimal.conf" "$ISO_STAGING/EFI/BOOT/refind.conf"
    # Copy kernel and initrd directly to the UEFI boot folder on the ISO
    # Copiar kernel e initrd directamente al directorio de arranque UEFI en la ISO
    $SUDO cp "$ISO_STAGING/live/vmlinuz" "$ISO_STAGING/EFI/BOOT/vmlinuz"
    $SUDO cp "$ISO_STAGING/live/initrd" "$ISO_STAGING/EFI/BOOT/initrd"

    # 2. Populate the efi.img for El Torito boot using mtools (resolves cluster size warnings)
    echo "📥 Copiando archivos a efi.img usando mtools..."
    $SUDO mmd -i "$EFI_IMG" ::/EFI
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/drivers_x64
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/themes
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/icons

    $SUDO mcopy -i "$EFI_IMG" "$ROOTFS_TARGET/usr/share/refind/refind/refind_x64.efi" ::/EFI/BOOT/bootx64.efi
    $SUDO mcopy -i "$EFI_IMG" "$ROOTFS_TARGET/usr/share/refind/refind/drivers_x64/"*iso9660*.efi ::/EFI/BOOT/drivers_x64/ 2>/dev/null || true
    $SUDO mcopy -i "$EFI_IMG" "$BUILD_DIR/refind.conf" ::/EFI/BOOT/refind.conf
    $SUDO mcopy -s -i "$EFI_IMG" "$ROOTFS_TARGET/usr/share/refind/refind/icons"/* ::/EFI/BOOT/icons/
    $SUDO mmd -i "$EFI_IMG" ::/EFI/BOOT/themes/rEFInd-Regular-Dark
    $SUDO mcopy -s -i "$EFI_IMG" "$BUILD_DIR/refind-mac-theme"/* ::/EFI/BOOT/themes/rEFInd-Regular-Dark/
    # Copy kernel and initrd directly to the efi.img FAT volume using mtools
    # Copiar kernel e initrd directamente al volumen FAT de efi.img usando mtools
    $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/vmlinuz" ::/EFI/BOOT/vmlinuz
    $SUDO mcopy -i "$EFI_IMG" "$ISO_STAGING/live/initrd" ::/EFI/BOOT/initrd

    # Cleanup temp build files
    $SUDO rm -f "$BUILD_DIR/refind.conf"
    $SUDO rm -f "$BUILD_DIR/refind-minimal.conf"
    $SUDO rm -rf "$BUILD_DIR/refind-mac-theme"

    if $WITH_NVIDIA; then
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-refind-${DISTRO}-nvidia.iso"
    else
        ISO_OUTPUT="$BUILD_DIR/pulsaros-${BRANCH}-refind-${DISTRO}.iso"
    fi
    echo "💿 Generando archivo ISO rEFInd en / Generating rEFInd ISO file at: $ISO_OUTPUT..."
    $SUDO xorriso -as mkisofs \
      -o "$ISO_OUTPUT" \
      -J -R -V "Pulsar OS" \
      -eltorito-alt-boot \
      -e "boot/efi.img" \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$ISO_STAGING"
fi

echo "=============================================================================="
echo "🎉 ¡ISO de Pulsar OS ($BOOTLOADER) generada con éxito!"
echo "📍 Ubicación / Location: $ISO_OUTPUT"
echo "=============================================================================="
