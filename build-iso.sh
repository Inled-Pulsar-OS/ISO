#!/bin/bash
# ==============================================================================
# Pulsar OS - Clean Chroot Builder (ISO Infrastructure)
# ==============================================================================
# Este script construye el sistema de archivos base (chroot) de Pulsar OS
# de forma totalmente limpia, evitando la acumulación de archivos residuales.
#
# Funcionamiento:
#   1. Comprueba e instala dependencias en el host con pkexec bajo confirmación.
#   2. Realiza un bootstrap virgen de Debian si no existe en la caché o si quedó corrupto.
#   3. Clona el Debian base virgen a un directorio de destino temporal (target).
#   4. Instala los paquetes locales .deb compilados o los descarga del repo APT.
#   5. Aplica configuraciones finales y deja el chroot listo para QEMU o la ISO.
#
# Uso:
#   ./build-iso.sh [--clean-base] [--local]
#
# Opciones:
#   --clean-base    Borra la caché base de Debian y la descarga de nuevo.
#   --local         Usa los paquetes .deb locales de build/packages/ en vez del repo.
# ==============================================================================

set -e

# ==============================================================================
# FASE 0: Comprobación de Dependencias del Host
# ==============================================================================

MISSING_PACKAGES=()

# Comprobar comandos estándar
for cmd in mmdebstrap fakeroot rsync jq curl unzip wget; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$cmd")
    fi
done

# Casos especiales de mapeo comando -> paquete
if ! command -v convert >/dev/null 2>&1; then
    MISSING_PACKAGES+=("imagemagick")
fi

if ! command -v fuser >/dev/null 2>&1; then
    MISSING_PACKAGES+=("psmisc")
fi

# IMPORTANTE: Comprobar el llavero de Debian en hosts Ubuntu/Debian no oficiales
if [ ! -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
    MISSING_PACKAGES+=("debian-archive-keyring")
fi

# Instalar dependencias si faltan
if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    echo "⚠️ Se ha detectado que faltan dependencias esenciales en el host: ${MISSING_PACKAGES[*]}"
    echo "Estas herramientas son requeridas para la compilación de Pulsar OS."
    read -p "¿Deseas instalar las dependencias faltantes ahora usando pkexec apt install? (s/n): " confirm
    if [[ "$confirm" =~ ^[sS]$ ]] || [[ "$confirm" =~ ^[yY]$ ]] || [ -z "$confirm" ]; then
        echo "📥 Iniciando instalación de dependencias..."
        pkexec apt-get update && pkexec apt-get install -y "${MISSING_PACKAGES[@]}"
        echo "✅ Dependencias instaladas con éxito."
    else
        echo "❌ Error: No se pueden cumplir los requisitos del host. Saliendo..."
        exit 1
    fi
fi

# ==============================================================================
# FASE 1: Configuración de Entorno e Inicialización
# ==============================================================================

# Importar configuración global si existe
if [ -f "../configs/env.sh" ]; then
    source ../configs/env.sh
elif [ -f "configs/env.sh" ]; then
    source configs/env.sh
else
    DEBIAN_VERSION="trixie"
    ARCH="amd64"
    MIRROR="http://deb.debian.org/debian"
fi

# Rutas del proyecto
ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ISO_DIR/build"
ROOTFS_BASE="$BUILD_DIR/rootfs-base"
ROOTFS_TARGET="$BUILD_DIR/rootfs-target"
PACKAGE_LIST_FILE="$ISO_DIR/../configs/base.list"

# Corregir rutas si el script se ejecuta en el repo ISO independiente
if [ ! -f "$PACKAGE_LIST_FILE" ]; then
    PACKAGE_LIST_FILE="$ISO_DIR/configs/base.list"
fi

# Parámetros
CLEAN_BASE=false
USE_LOCAL_DEBS=false

for arg in "$@"; do
    case $arg in
        --clean-base)
            CLEAN_BASE=true
            shift
            ;;
        --local)
            USE_LOCAL_DEBS=true
            shift
            ;;
    esac
done

# Detección dinámica de la ruta de chroot en el host (resuelve diferencias entre /usr/sbin/chroot y /usr/bin/chroot)
CHROOT_BIN=$(command -v chroot || echo "/usr/sbin/chroot")

# Función de limpieza preventiva para asegurar desmontajes en caso de interrupción
cleanup() {
    echo "🧹 Finalizando y liberando recursos montados en el chroot..."
    pkexec umount -l "$ROOTFS_TARGET/proc" 2>/dev/null || true
    pkexec umount -l "$ROOTFS_TARGET/sys" 2>/dev/null || true
    pkexec umount -l "$ROOTFS_TARGET/dev/pts" 2>/dev/null || true
    pkexec umount -l "$ROOTFS_TARGET/dev" 2>/dev/null || true
    
    # Restaurar DNS original en el target si quedó copia
    if [ -f "$ROOTFS_TARGET/etc/resolv.conf.bak" ]; then
        pkexec mv "$ROOTFS_TARGET/etc/resolv.conf.bak" "$ROOTFS_TARGET/etc/resolv.conf" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ==============================================================================
# FASE 2: Construcción y mantenimiento del Debian Base Virgen (Caché)
# ==============================================================================

# Robustez: Auto-limpieza en caso de bootstrap anterior incompleto o corrupto
if [ -d "$ROOTFS_BASE" ] && { [ ! -d "$ROOTFS_BASE/etc" ] || [ ! -d "$ROOTFS_BASE/proc" ] || [ ! -d "$ROOTFS_BASE/boot" ]; }; then
    echo "⚠️ Caché del Debian Base incompleta o corrupta detectada (posible interrupción previa). Limpiando para regenerar..."
    cleanup
    pkexec rm -rf "$ROOTFS_BASE"
fi

if $CLEAN_BASE; then
    echo "🚨 Limpieza total de la caché Debian base solicitada..."
    cleanup
    pkexec rm -rf "$ROOTFS_BASE"
fi

if [ ! -d "$ROOTFS_BASE/etc" ]; then
    echo "--- 📥 Creando Debian Base Limpio (mmdebstrap) ---"
    mkdir -p "$BUILD_DIR"
    
    # Limpiar el listado de paquetes base para mmdebstrap
    if [ ! -f "$PACKAGE_LIST_FILE" ]; then
        echo "❌ Error: No se encontró el archivo de paquetes base en: $PACKAGE_LIST_FILE"
        exit 1
    fi
    
    PACKAGE_LIST=$(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
    
    # Agregar el llavero de Debian si existe en el host (requerido en Ubuntu/Mint)
    KEYRING_PARAM=""
    if [ -f "/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        KEYRING_PARAM="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
        echo "🔑 Usando llavero de Debian: /usr/share/keyrings/debian-archive-keyring.gpg"
    fi
    
    # Ejecutar bootstrap de Debian Virgen
    pkexec /usr/bin/mmdebstrap \
        --architecture="$ARCH" \
        --variant=apt \
        $KEYRING_PARAM \
        --include="$PACKAGE_LIST" \
        "$DEBIAN_VERSION" \
        "$ROOTFS_BASE" \
        "$MIRROR"
        
    echo "✅ Bootstrap de Debian base completado en: $ROOTFS_BASE"
else
    echo "✨ Debian Base Virgen detectado en caché. Saltando bootstrap."
fi

# ==============================================================================
# FASE 3: Clonar base limpia para aplicar cambios
# ==============================================================================

echo "--- 🔄 Clonando Debian Virgen en el directorio de trabajo (target) ---"
# Asegurar desmontajes previos
cleanup
pkexec rm -rf "$ROOTFS_TARGET"
mkdir -p "$ROOTFS_TARGET"

# Sincronización súper rápida manteniendo atributos especiales
pkexec rsync -aHAXx --delete "$ROOTFS_BASE/" "$ROOTFS_TARGET/"

# ==============================================================================
# FASE 4: Montar directorios del sistema y configurar red
# ==============================================================================

echo "⚙️ Configurando montajes virtuales y DNS..."
pkexec mount -t proc proc "$ROOTFS_TARGET/proc"
pkexec mount -t sysfs sys "$ROOTFS_TARGET/sys"
pkexec mount --bind /dev "$ROOTFS_TARGET/dev"
pkexec mount --bind /dev/pts "$ROOTFS_TARGET/dev/pts"

# Asegurar DNS funcional en el chroot
if [ -f "$ROOTFS_TARGET/etc/resolv.conf" ]; then
    pkexec cp "$ROOTFS_TARGET/etc/resolv.conf" "$ROOTFS_TARGET/etc/resolv.conf.bak"
fi
echo "nameserver 8.8.8.8" | pkexec tee "$ROOTFS_TARGET/etc/resolv.conf" > /dev/null

# ==============================================================================
# FASE 5: Configurar Repositorios e Instalar Paquetes de Pulsar OS
# ==============================================================================

echo "--- 🌐 Configurando repositorios APT (Debian Contrib/Backports e Inled) ---"
# English: Enable contrib, non-free, non-free-firmware, and backports in target chroot sources list
# Español: Habilitar contrib, non-free, non-free-firmware y backports en la lista de fuentes del chroot
pkexec sed -i "s/$DEBIAN_VERSION main/$DEBIAN_VERSION main contrib non-free non-free-firmware/g" "$ROOTFS_TARGET/etc/apt/sources.list"
if ! grep -q "${DEBIAN_VERSION}-backports" "$ROOTFS_TARGET/etc/apt/sources.list"; then
    echo "deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware" | pkexec tee -a "$ROOTFS_TARGET/etc/apt/sources.list" > /dev/null
fi

# English: Configure Inled APT GPG key and sources list in the chroot
# Español: Configurar la clave GPG y la lista de fuentes de Inled APT en el chroot
pkexec "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    set -e
    apt-get update && apt-get install -y wget gnupg ca-certificates
    wget -qO- https://apt.inled.es/archive.key | gpg --dearmor | tee /usr/share/keyrings/inled-archive-keyring.gpg > /dev/null
"

echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es stable main" | \
    pkexec tee "$ROOTFS_TARGET/etc/apt/sources.list.d/inled.list" > /dev/null

if $USE_LOCAL_DEBS; then
    echo "--- 🛠️ MODO DESARROLLO LOCAL: Instalando paquetes .deb locales ---"
    
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
    
    # Copiar de forma segura debs al chroot temporal
    pkexec mkdir -p "$ROOTFS_TARGET/tmp/packages"
    pkexec cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"
    
    # Instalar paquetes locales directamente y resolver dependencias
    pkexec "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        apt-get update
        apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
        apt-get install -y --fix-broken /tmp/packages/*.deb droidtux macboat appinstall seafari
        apt-get clean
    "
    # Limpiar instaladores temporales
    pkexec rm -rf "$ROOTFS_TARGET/tmp/packages"
    echo "✅ Paquetes locales de Pulsar OS y repositorios externos instalados correctamente."
else
    echo "--- 🌐 MODO PRODUCCIÓN: Instalando paquetes desde repositorio APT ---"
    
    # 3. Actualizar e instalar el metapaquete o paquetes específicos
    echo "Instalando paquetes de Pulsar OS..."
    pkexec "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
        set -e
        apt-get update
        apt-get install -y -t ${DEBIAN_VERSION}-backports scrcpy
        apt-get install -y --no-install-recommends \
            pulsaros-branding \
            pulsaros-theme \
            pulsaros-gnome \
            pulsaros-global-menu \
            pulsaros-spotlight-launcher \
            pulsaros-sddm \
            pulsaros-plymouth \
            pulsaros-grub \
            pulsaros-calamares \
            pulsaros-essential \
            pulsaros-welcome \
            pulsaros-recovery \
            droidtux \
            macboat \
            appinstall \
            seafari
        apt-get clean
    "
    echo "✅ Paquetes de Pulsar OS instalados desde repositorio APT."
fi

# ==============================================================================
# FASE 5.5: Configuración de Aplicaciones del Sistema (Flatpak y Spotlight)
# ==============================================================================

# English: Download spotlight-python and winboat deb packages on the host and copy them to the chroot
# Español: Descargar los paquetes deb de spotlight-python y winboat en el host y copiarlos al chroot
echo "📥 Descargando dependencias externas (Spotlight-Python y Winboat) en el host..."
wget -q -O /tmp/spotlight-python.deb https://github.com/InledGroup/spotlight-gtk/releases/download/v1.0.12/spotlight-python.deb
wget -q -O /tmp/winboat.deb https://github.com/TibixDev/winboat/releases/download/v0.9.0/winboat-0.9.0-amd64.deb
pkexec cp /tmp/spotlight-python.deb /tmp/winboat.deb "$ROOTFS_TARGET/tmp/"

# English: Install flatpak, gnome-software plugin, spotlight-python, and winboat
# Español: Instalar flatpak, el plugin de gnome-software, spotlight-python y winboat
echo "⚙️ Configurando Flatpak, GNOME Software, Spotlight-Python y Winboat dentro del chroot..."
pkexec "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    set -e
    
    # Instalar flatpak y el plugin de GNOME Software
    echo '📥 Instalando Flatpak y plugin de GNOME Software...'
    apt-get update
    apt-get install -y flatpak gnome-software-plugin-flatpak
    
    # Configurar el repositorio Flathub a nivel de sistema
    echo '🌐 Configurando repositorio de Flathub...'
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    
    # Instalar spotlight-python
    echo '📥 Instalando Spotlight-Python...'
    apt-get install -y /tmp/spotlight-python.deb
    rm -f /tmp/spotlight-python.deb
    
    # Instalar winboat
    echo '📥 Instalando Winboat...'
    apt-get install -y /tmp/winboat.deb
    rm -f /tmp/winboat.deb
    
    # Configurar el icono de spotlight-python a 'view-app-grid'
    # Configure the icon of spotlight-python to 'view-app-grid'
    echo '⚙️ Personalizando lanzador de Spotlight...'
    if [ -f /usr/share/applications/spotlight-python.desktop ]; then
        sed -i 's/^Icon=.*/Icon=view-app-grid/' /usr/share/applications/spotlight-python.desktop
    fi
"

# ==============================================================================
# FASE 6: Tareas Finales del Sistema (Generación de Kernel y Limpieza)
# ==============================================================================

echo "--- 🔄 Finalizando y actualizando initramfs ---"
pkexec "$CHROOT_BIN" "$ROOTFS_TARGET" /bin/bash -c "
    update-initramfs -u -k all
"

echo "✨ Proceso finalizado con éxito total. El rootfs limpio de Pulsar OS está en: $ROOTFS_TARGET"
echo "Para probar el resultado en QEMU, ejecuta: ./run-qemu.sh"
