#!/bin/bash
# ==============================================================================
# Pulsar OS - Clean Chroot and Live ISO Builder
# ==============================================================================
# This script builds the clean chroot base file system for Pulsar OS,
# installs packages from the local builds or the APT repository, and packages
# everything into a bootable hybrid Live CD ISO image.
#
# Este script construye el sistema de archivos base (chroot) de Pulsar OS,
# instala paquetes locales o desde el repositorio APT, y empaqueta todo en
# una imagen ISO booteable híbrida de Live CD.
#
# Usage / Uso:
#   ./build-iso.sh [--clean-base] [--local]
#
# Options / Opciones:
#   --clean-base    Delete the base Debian cache and download it from scratch.
#                   Borra la caché base de Debian y la descarga de nuevo.
#   --local         Use local .deb packages from build/packages/ instead of the repo.
#                   Usa los paquetes .deb locales de build/packages/ en vez del repo.
# ==============================================================================

set -e

# ==============================================================================
# Parse Arguments / Parámetros
# ==============================================================================
CLEAN_BASE=false
USE_LOCAL_DEBS=false
BOOTLOADER="grub" # Default bootloader is GRUB / El cargador por defecto es GRUB

for arg in "$@"; do
    case $arg in
        --clean-base)
            CLEAN_BASE=true
            ;;
        --local)
            USE_LOCAL_DEBS=true
            ;;
        --refind)
            BOOTLOADER="refind"
            ;;
        --grub)
            BOOTLOADER="grub"
            ;;
    esac
done

# ==============================================================================
# Check Host Dependencies / Comprobación de Dependencias del Host
# ==============================================================================
MISSING_PACKAGES=()

# Check standard commands / Comprobar comandos estándar
CMDS=("mmdebstrap" "fakeroot" "rsync" "jq" "curl" "unzip" "wget" "mksquashfs" "xorriso")
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

if [ "$BOOTLOADER" = "grub" ]; then
    # We also need the BIOS and UEFI build files for grub-mkrescue
    # También necesitamos los archivos de construcción BIOS y UEFI para grub-mkrescue
    if ! dpkg -l | grep -q "grub-pc-bin"; then
        MISSING_PACKAGES+=("grub-pc-bin")
    fi
    if ! dpkg -l | grep -q "grub-efi-amd64-bin"; then
        MISSING_PACKAGES+=("grub-efi-amd64-bin")
    fi
else
    # We only need mtools on the host to generate the bootable EFI image for rEFInd
    # (rEFInd binaries and icons are copied directly from the target chroot to avoid overwriting the host bootloader)
    # Solo necesitamos mtools en el host para generar la imagen EFI arrancable de rEFInd
    # (Los binarios e iconos de rEFInd se copian directamente del chroot para evitar sobrescribir el cargador del host)
    if ! dpkg -l | grep -q "mtools"; then
        MISSING_PACKAGES+=("mtools")
    fi
fi

# IMPORTANT: Check Debian archive keyring on non-Debian host distros (like Ubuntu/Mint)
# IMPORTANTE: Comprobar el llavero de Debian en hosts Ubuntu/Debian no oficiales
if [ ! -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
    MISSING_PACKAGES+=("debian-archive-keyring")
fi

# Install dependencies if they are missing / Instalar dependencias si faltan
if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    echo "⚠️ Se ha detectado que faltan dependencias esenciales en el host: ${MISSING_PACKAGES[*]}"
    echo "Estas herramientas son requeridas para la compilación de Pulsar OS ($BOOTLOADER)."
    
    # Auto-approve if in non-interactive environment (CI, pipeline, no TTY stdin)
    # Aprobación automática si estamos en un entorno no interactivo (CI, pipeline, sin TTY stdin)
    auto_install=false
    if [ "$GITHUB_ACTIONS" = "true" ] || [ ! -t 0 ]; then
        auto_install=true
    else
        read -p "¿Deseas instalar las dependencias faltantes ahora usando apt install? (s/n): " confirm
        if [[ "$confirm" =~ ^[sS]$ ]] || [[ "$confirm" =~ ^[yY]$ ]] || [ -z "$confirm" ]; then
            auto_install=true
        fi
    fi
    
    if [ "$auto_install" = true ]; then
        echo "📥 Iniciando instalación de dependencias..."
        if command -v pkexec >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
            # Run in a single pkexec bash session to prevent double password prompts
            # Ejecutar en una sola sesión de bash con pkexec para evitar dobles solicitudes de contraseña
            pkexec /bin/bash -c "apt-get update && apt-get install -y ${MISSING_PACKAGES[*]}"
        else
            sudo apt-get update && sudo apt-get install -y "${MISSING_PACKAGES[@]}"
        fi
        echo "✅ Dependencias instaladas con éxito."
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
        exec pkexec "$0" "$@"
    else
        exec sudo "$0" "$@"
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
    DEBIAN_VERSION="trixie"
    ARCH="amd64"
    MIRROR="http://deb.debian.org/debian"
fi

# Paths in the project / Rutas del proyecto
ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ISO_DIR/build"
ROOTFS_BASE="$BUILD_DIR/rootfs-base"
ROOTFS_TARGET="$BUILD_DIR/rootfs-target"
PACKAGE_LIST_FILE="$ISO_DIR/configs/base.list"

# Adjust paths / Fallback to root repo configuration if local config is missing
# Corregir rutas / Usar configuración del repo raíz como fallback si no existe el de la ISO
if [ ! -f "$PACKAGE_LIST_FILE" ]; then
    PACKAGE_LIST_FILE="$ISO_DIR/../configs/base.list"
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
    
    # Restore original DNS config in target if backup exists
    # Restaurar DNS original en el target si quedó copia
    if [ -f "$ROOTFS_TARGET/etc/resolv.conf.bak" ]; then
        $SUDO mv "$ROOTFS_TARGET/etc/resolv.conf.bak" "$ROOTFS_TARGET/etc/resolv.conf" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ==============================================================================
# PHASE 2: Build and Maintain Base Debian Cache / FASE 2: Caché Debian Base Virgen
# ==============================================================================

# Auto-cleanup if previous bootstrap was incomplete or corrupted
# Auto-limpieza en caso de bootstrap anterior incompleto o corrupto
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/proc" ] || [ ! -d "$ROOTFS_BASE/boot" ]; }; then
    echo "⚠️ Caché del Debian Base incompleta o corrupta detectada. Limpiando para regenerar..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
fi

# Detect if base.list has changed since the cache was created
# Detectar si base.list ha cambiado desde que se creó la caché
base_list_changed=false
if [ -d "$ROOTFS_BASE" ] && [ -f "$PACKAGE_LIST_FILE" ]; then
    if [ ! -f "$ROOTFS_BASE/etc/pulsaros-base.list" ] || ! diff -q "$PACKAGE_LIST_FILE" "$ROOTFS_BASE/etc/pulsaros-base.list" >/dev/null 2>&1; then
        echo "🔄 Se ha detectado un cambio en base.list con respecto al Debian Base en caché. Regenerando base..."
        base_list_changed=true
    fi
fi

if $CLEAN_BASE || [ "$base_list_changed" = true ]; then
    echo "🚨 Limpieza total de la caché Debian base solicitada..."
    cleanup
    $SUDO rm -rf "$ROOTFS_BASE"
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    echo "--- 📥 Creando Debian Base Limpio (mmdebstrap) ---"
    mkdir -p "$BUILD_DIR"
    
    if [ ! -f "$PACKAGE_LIST_FILE" ]; then
        echo "❌ Error: No se encontró el archivo de paquetes base en: $PACKAGE_LIST_FILE"
        exit 1
    fi
    
    PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
    
    # Add Debian keyring parameter if it exists (required on Ubuntu/Mint hosts)
    # Agregar el llavero de Debian si existe en el host (requerido en Ubuntu/Mint)
    KEYRING_PARAM=""
    if [ -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        KEYRING_PARAM="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
        echo "🔑 Usando llavero de Debian: /usr/share/keyrings/debian-archive-keyring.gpg"
    fi
    
    # Execute Debian Bootstrap
    # Ejecutar bootstrap de Debian Virgen
    $SUDO /usr/bin/mmdebstrap \
        --architecture="$ARCH" \
        --variant=apt \
        $KEYRING_PARAM \
        --include="$PACKAGE_LIST" \
        "$DEBIAN_VERSION" \
        "$ROOTFS_BASE" \
        "$MIRROR"
        
    # Save a copy of base.list in the base cache for future diffs
    # Guardar una copia de base.list en la caché base para futuras comparaciones
    $SUDO cp "$PACKAGE_LIST_FILE" "$ROOTFS_BASE/etc/pulsaros-base.list"
    
    echo "✅ Bootstrap de Debian base completado en: $ROOTFS_BASE"
else
    echo "✨ Debian Base Virgen detectado en caché. Saltando bootstrap."
fi

# ==============================================================================
# PHASE 3: Clone clean base for working target / FASE 3: Clonar base limpia
# ==============================================================================

echo "--- 🔄 Clonando Debian Virgen en el directorio de trabajo (target) ---"
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

echo "--- 🌐 Configurando repositorios APT (Debian Contrib/Backports e Inled) ---"
$SUDO sed -i "s/$DEBIAN_VERSION main/$DEBIAN_VERSION main contrib non-free non-free-firmware/g" "$ROOTFS_TARGET/etc/apt/sources.list"
if ! grep -q "${DEBIAN_VERSION}-backports" "$ROOTFS_TARGET/etc/apt/sources.list"; then
    echo "deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware" | $SUDO tee -a "$ROOTFS_TARGET/etc/apt/sources.list" > /dev/null
fi

# Copy the bundled Inled APT GPG keyring directly to the chroot target
# Copiar el llavero GPG de Inled pre-empaquetado directamente al chroot target
echo "🔑 Copiando el llavero GPG de Inled pre-empaquetado..."
$SUDO mkdir -p "$ROOTFS_TARGET/usr/share/keyrings"
$SUDO cp "$ISO_DIR/configs/inled-archive-keyring.gpg" "$ROOTFS_TARGET/usr/share/keyrings/inled-archive-keyring.gpg"

echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es stable main" | \
    $SUDO tee "$ROOTFS_TARGET/etc/apt/sources.list.d/inled.list" > /dev/null

# Create temporary dpkg-diverts to intercept DroidTux's and AppInstall's keyring setup (preventing 403/interactive prompts)
# Crear desvíos de dpkg temporales para interceptar la auto-configuración del repo de DroidTux y AppInstall y evitar 403 y prompts interactivos
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
    
    # 1. Auto-compile local packages from the neighboring PKG repository
    # 1. Compilar automáticamente los paquetes locales desde el repositorio vecino PKG
    pkg_dir_source="$ISO_DIR/../PKG"
    if [ ! -d "$pkg_dir_source" ]; then
        pkg_dir_source="/home/jaime/Documentos/pulsarbase/PKG"
    fi
    
    if [ -f "$pkg_dir_source/package-and-deploy.sh" ]; then
        echo "🔨 Compilando todos los paquetes locales de forma fresca..."
        (cd "$pkg_dir_source" && ./package-and-deploy.sh all)
    else
        echo "⚠️ Advertencia: No se encontró el script de empaquetado en $pkg_dir_source/package-and-deploy.sh. Se intentará usar debs pre-existentes."
    fi
    
    # Search in multiple potential packages build locations
    # Buscar paquetes locales en múltiples rutas comunes de desarrollo
    LOCAL_DEBS_DIR=""
    POSSIBLE_DIRS=(
        "$ISO_DIR/../PKG/build/packages" # Estructura actual de repos vecinos
        "$ISO_DIR/../build/packages"     # Estructura del proyecto monolítico
        "$ISO_DIR/build/packages"        # Directorio interno del repo ISO
        "/home/jaime/Documentos/pulsarbase/PKG/build/packages" # Ruta absoluta del host
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
    
    # Copy debs securely to the temporary staging chroot
    # Copiar de forma segura debs al chroot temporal
    $SUDO mkdir -p "$ROOTFS_TARGET/tmp/packages"
    $SUDO cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"
    if [ "$BOOTLOADER" = "grub" ]; then
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-refind_*.deb
    else
        $SUDO rm -f "$ROOTFS_TARGET/tmp/packages"/pulsaros-grub_*.deb
    fi
    
    # Determine the bootloader packages to pull explicitly inside chroot
    # Determinar los paquetes del cargador de arranque a instalar explícitamente en el chroot
    if [ "$BOOTLOADER" = "grub" ]; then
        BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin"
    else
        BOOTLOADER_PKGS="refind efibootmgr"
    fi
    
    # Install local packages and resolve dependencies, pulling non-local from APT
    # Instalar paquetes locales directamente y resolver dependencias, bajando externos de APT
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        # Pre-seed refind to not automatically install to the ESP of the build host chroot
        # Preconfigurar refind para que no intente instalarse automáticamente en la ESP del host de compilación
        echo 'refind refind/install_to_esp boolean false' | debconf-set-selections
        apt-get update
        yes | apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
        yes | apt-get install -y --no-install-recommends $BOOTLOADER_PKGS
        # English: Install local debs first using dpkg to force their use, avoiding repository override
        # Español: Instalar debs locales primero usando dpkg para forzar su uso, evitando sobrescritura del repositorio
        dpkg -i /tmp/packages/*.deb || true
        # English: Resolve dependencies of local packages first without adding new ones, which is required by apt
        # Español: Resolver dependencias de paquetes locales primero sin añadir nuevos, lo cual es requerido por apt
        yes | apt-get install -y --fix-broken
        # English: Install remote OS packages once the package system state is clean
        # Español: Instalar paquetes remotos del sistema operativo una vez que el estado de paquetes esté limpio
        yes | apt-get install -y droidtux macboat appinstall seafari spotlight-python
        yes | apt-get purge -y live-config live-config-systemd || true
        apt-get clean
    "
    # Clean up temporary installers / Limpiar instaladores temporales
    $SUDO rm -rf "$ROOTFS_TARGET/tmp/packages"
    echo "✅ Paquetes locales e instalados de forma cruzada con éxito."
else
    echo "--- 🌐 MODO PRODUCCIÓN: Instalando paquetes desde repositorio APT ---"
    
    # Determine the bootloader packages to pull explicitly inside chroot
    # Determinar los paquetes del cargador de arranque a instalar explícitamente en el chroot
    if [ "$BOOTLOADER" = "grub" ]; then
        BOOTLOADER_PKGS="grub-pc grub-efi-amd64-bin"
    else
        BOOTLOADER_PKGS="refind efibootmgr"
    fi

    # Install metapackages and specific OS components from the Inled APT repo
    # Instalar paquetes de Pulsar OS desde el repositorio de APT
    $SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        # Pre-seed refind to not automatically install to the ESP of the build host chroot
        # Preconfigurar refind para que no intente instalarse automáticamente en la ESP del host de compilación
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
            pulsaros-$BOOTLOADER \
            pulsaros-calamares \
            pulsaros-essential \
            pulsaros-welcome \
            pulsaros-recovery \
            pulsaros-bootsound \
            pulsar-macos-keyboard-remap-x11 \
            droidtux \
            macboat \
            appinstall \
            seafari \
            spotlight-python
        yes | apt-get purge -y live-config live-config-systemd || true
        apt-get clean
    "
fi

# Dynamically adjust Calamares configuration inside chroot based on selected bootloader
# Ajustar dinámicamente la configuración de Calamares en el chroot según el cargador de arranque seleccionado
if [ "$BOOTLOADER" = "refind" ]; then
    echo "⚙️ Configurando Calamares para rEFInd (removiendo módulos de GRUB)..."
    if [ -f "$ROOTFS_TARGET/etc/calamares/settings.conf" ]; then
        $SUDO sed -i 's/- grubcfg/- shellprocess@refind/' "$ROOTFS_TARGET/etc/calamares/settings.conf"
        $SUDO sed -i '/- bootloader/d' "$ROOTFS_TARGET/etc/calamares/settings.conf"
    fi
else
    echo "⚙️ Calamares configurado para GRUB (módulos por defecto)."
fi

# Clean up temporary DroidTux and AppInstall mocks and restore dpkg-diverts
# Limpiar los mocks temporales de DroidTux y AppInstall y restaurar desvíos de dpkg
echo "🧹 Limpiando mocks y desvíos de dpkg de DroidTux y AppInstall..."
$SUDO rm -f "$ROOTFS_TARGET/usr/bin/curl"
$SUDO rm -f "$ROOTFS_TARGET/usr/bin/wget"
$SUDO rm -f "$ROOTFS_TARGET/usr/bin/gpg"

$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    dpkg-divert --remove --rename /usr/bin/curl
    dpkg-divert --remove --rename /usr/bin/wget
    dpkg-divert --remove --rename /usr/bin/gpg
"

# ==============================================================================
# PHASE 5.5: Configure System Apps (Flatpak and External Winboat)
# FASE 5.5: Configuración de Aplicaciones del Sistema (Flatpak y Winboat)
# ==============================================================================

# Download external winboat dependencies on host and copy to chroot
# Descargar dependencias externas de winboat en el host y copiarlas al chroot
echo "📥 Descargando dependencias externas (Winboat) en el host..."
wget -q --timeout=15 --tries=3 -O "$BUILD_DIR/winboat.deb" https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-amd64.deb
$SUDO cp "$BUILD_DIR/winboat.deb" "$ROOTFS_TARGET/tmp/winboat.deb"
rm -f "$BUILD_DIR/winboat.deb"

echo "⚙️ Configurando Flatpak, GNOME Software y Winboat dentro del chroot..."
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    set -e
    
    # Install flatpak and plugin / Instalar flatpak y el plugin de GNOME Software
    echo '📥 Instalando Flatpak y plugin de GNOME Software...'
    apt-get update
    apt-get install -y flatpak gnome-software-plugin-flatpak
    
    # Configure Flathub at system level / Configurar el repositorio Flathub a nivel de sistema
    echo '🌐 Configurando repositorio de Flathub...'
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    
    # Install winboat / Instalar winboat
    echo '📥 Instalando Winboat...'
    apt-get install -y /tmp/winboat.deb
    rm -f /tmp/winboat.deb
    
    # Configure spotlight-python icon / Configurar el icono de spotlight-python a 'view-app-grid'
    echo '⚙️ Personalizando lanzador de Spotlight...'
    if [ -f /usr/share/applications/spotlight-python.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-python.desktop
    fi
"

# English: Configure static autologin for SDDM live user inside the rootfs
# Español: Configurar autologin estático para el usuario live de SDDM en el rootfs
echo "⚙️ Configurando autologin estático para la sesión en vivo..."
$SUDO mkdir -p "$ROOTFS_TARGET/etc/sddm.conf.d"
cat <<EOF | $SUDO tee "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf" > /dev/null
[Autologin]
User=live
Session=gnome-xorg
EOF
$SUDO chmod 644 "$ROOTFS_TARGET/etc/sddm.conf.d/autologin.conf"

# ==============================================================================
# PHASE 6: Final Tasks (Initramfs regeneration and cleanup)
# FASE 6: Tareas Finales del Sistema (Generación de Kernel y Limpieza)
# ==============================================================================

echo "--- 🔄 Finalizando y actualizando initramfs ---"
$SUDO "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    update-initramfs -u -k all
"

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

# 1. Compress rootfs into SquashFS / Comprimir el rootfs en SquashFS
echo "📦 Comprimiendo rootfs en SquashFS (esto puede tardar unos minutos)... / Compressing rootfs into SquashFS..."
# Exclude dynamic/temp directories and virtual filesystems to save space and prevent errors
# Excluimos directorios dinámicos, temporales y sistemas de archivos virtuales para ahorrar espacio y evitar errores
$SUDO mksquashfs "$ROOTFS_TARGET" "$ISO_STAGING/live/filesystem.squashfs" \
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
KERNEL_FILE=$(ls "$ROOTFS_TARGET"/boot/vmlinuz-* 2>/dev/null | head -n 1)
INITRD_FILE=$(ls "$ROOTFS_TARGET"/boot/initrd.img-* 2>/dev/null | head -n 1)

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
    if [ -d "$ROOTFS_TARGET/usr/share/grub/themes/Particle-circle-window" ]; then
        echo "🎨 Copiando tema de GRUB de Pulsar OS a la ISO staging..."
        $SUDO mkdir -p "$ISO_STAGING/boot/grub/themes"
        $SUDO cp -r "$ROOTFS_TARGET/usr/share/grub/themes/Particle-circle-window" "$ISO_STAGING/boot/grub/themes/"
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

loadfont /boot/grub/themes/Particle-circle-window/terminus-12.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-14.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-16.pf2
loadfont /boot/grub/themes/Particle-circle-window/terminus-18.pf2
loadfont /boot/grub/themes/Particle-circle-window/unifont-16.pf2
set theme=/boot/grub/themes/Particle-circle-window/theme.txt

menuentry "Pulsar OS Live (RAM)" {
    linux /live/vmlinuz boot=live components username=live autologin quiet splash loglevel=3 --
    initrd /live/initrd
}
EOF

    ISO_OUTPUT="$BUILD_DIR/pulsaros.iso"
    echo "💿 Generando archivo ISO GRUB en / Generating GRUB ISO file at: $ISO_OUTPUT..."
    $SUDO grub-mkrescue -o "$ISO_OUTPUT" "$ISO_STAGING"

else
    # --------------------------------------------------------------------------
    # rEFInd BOOTLOADER PACKAGING
    # --------------------------------------------------------------------------
    echo "💿 Creando imagen EFI bootable con rEFInd... / Creating bootable EFI image with rEFInd..."
    $SUDO mkdir -p "$ISO_STAGING/boot"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT"
    EFI_IMG="$ISO_STAGING/boot/efi.img"

    # Create an 80MB empty file and format it as FAT16 (eliminates FAT32 cluster warnings and has space for kernel/initrd)
    # Crear un archivo vacío de 80MB y formatearlo en FAT16 (elimina avisos de clúster de FAT32 y tiene espacio para kernel/initrd)
    $SUDO dd if=/dev/zero of="$EFI_IMG" bs=1M count=80 2>/dev/null
    $SUDO mkfs.vfat -F 16 "$EFI_IMG" >/dev/null

    # Create temporary refind.conf for the ISO boot
    cat <<EOF > "$BUILD_DIR/refind.conf"
timeout 10
enable_mouse
resolution 1024 768
include themes/rEFInd-Regular-Dark/theme.conf

menuentry "Pulsar OS Live" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_debian.png
    loader /EFI/BOOT/vmlinuz
    initrd /EFI/BOOT/initrd
    options "boot=live components username=live autologin quiet splash loglevel=3 --"
}
EOF

    # Clone the theme (using HTTP/1.1, low speed timeouts, and larger postBuffer to prevent HTTP/2 curl 92 errors and hangs)
    # Clonar el tema (usando HTTP/1.1, límites de velocidad baja, y postBuffer mayor para evitar errores curl 92 y cuelgues)
    echo "🎨 Descargando tema macOS de rEFInd..."
    $SUDO rm -rf "$BUILD_DIR/refind-mac-theme"
    $SUDO git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --depth=1 "https://github.com/Inled-Pulsar-OS/refind-mac-theme" "$BUILD_DIR/refind-mac-theme"
    $SUDO sed -i '/#MENUENTRIES/q' "$BUILD_DIR/refind-mac-theme/theme.conf"

    # 1. Populate the ISO root /EFI/BOOT folder for direct UEFI boot (resolves QEMU boot problems)
    echo "📂 Copiando archivos de rEFInd, kernel e initrd a la raíz de la ISO staging..."
    $SUDO cp "$ROOTFS_TARGET/usr/share/refind/refind/refind_x64.efi" "$ISO_STAGING/EFI/BOOT/bootx64.efi"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT/drivers_x64"
    $SUDO cp "$ROOTFS_TARGET/usr/share/refind/refind/drivers_x64/"*iso9660*.efi "$ISO_STAGING/EFI/BOOT/drivers_x64/" 2>/dev/null || true
    $SUDO cp "$BUILD_DIR/refind.conf" "$ISO_STAGING/EFI/BOOT/refind.conf"
    $SUDO cp -r "$ROOTFS_TARGET/usr/share/refind/refind/icons" "$ISO_STAGING/EFI/BOOT/"
    $SUDO mkdir -p "$ISO_STAGING/EFI/BOOT/themes/rEFInd-Regular-Dark"
    $SUDO cp -r "$BUILD_DIR/refind-mac-theme"/* "$ISO_STAGING/EFI/BOOT/themes/rEFInd-Regular-Dark/"
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
    $SUDO rm -rf "$BUILD_DIR/refind-mac-theme"

    ISO_OUTPUT="$BUILD_DIR/pulsaros-refind.iso"
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
