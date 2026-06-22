#!/bin/bash
# ==============================================================================
# Pulsar OS - Clean Chroot Builder (ISO Infrastructure)
# ==============================================================================
# Este script construye el sistema de archivos base (chroot) de Pulsar OS
# de forma totalmente limpia, evitando la acumulación de archivos residuales.
#
# Funcionamiento:
#   1. Realiza un bootstrap virgen de Debian si no existe en la caché.
#   2. Clona el Debian base virgen a un directorio de destino temporal (target).
#   3. Instala los paquetes locales .deb compilados o los descarga del repo APT.
#   4. Aplica configuraciones finales y deja el chroot listo para QEMU o la ISO.
#
# Uso:
#   ./build-iso.sh [--clean-base] [--local]
#
# Opciones:
#   --clean-base    Borra la caché base de Debian y la descarga de nuevo.
#   --local         Usa los paquetes .deb locales de build/packages/ en vez del repo.
# ==============================================================================

set -e

# Importar configuración global
# Si configs/env.sh no existe localmente, definimos valores predeterminados
if [ -f "../configs/env.sh" ]; then
    source ../configs/env.sh
elif [ -f "configs/env.sh" ]; then
    source configs/env.sh
else
    DEBIAN_VERSION="trixie"
    ARCH="amd64"
    MIRROR="http://deb.debian.org/debian"
fi

# Rutas del proyecto (asumiendo ejecución desde la raíz del repo ISO)
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
# FASE 1: Construcción y mantenimiento del Debian Base Virgen (Caché)
# ==============================================================================

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
    
    # Ejecutar bootstrap de Debian Virgen
    pkexec /usr/bin/mmdebstrap \
        --architecture="$ARCH" \
        --variant=apt \
        --include="$PACKAGE_LIST" \
        "$DEBIAN_VERSION" \
        "$ROOTFS_BASE" \
        "$MIRROR"
        
    echo "✅ Bootstrap de Debian base completado en: $ROOTFS_BASE"
else
    echo "✨ Debian Base Virgen detectado en caché. Saltando bootstrap."
fi

# ==============================================================================
# FASE 2: Clonar base limpia para aplicar cambios
# ==============================================================================

echo "--- 🔄 Clonando Debian Virgen en el directorio de trabajo (target) ---"
# Asegurar desmontajes previos
cleanup
pkexec rm -rf "$ROOTFS_TARGET"
mkdir -p "$ROOTFS_TARGET"

# Sincronización súper rápida manteniendo atributos especiales
pkexec rsync -aHAXx --delete "$ROOTFS_BASE/" "$ROOTFS_TARGET/"

# ==============================================================================
# FASE 3: Montar directorios del sistema y configurar red
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
# FASE 4: Configurar Repositorios e Instalar Paquetes de Pulsar OS
# ==============================================================================

if $USE_LOCAL_DEBS; then
    echo "--- 🛠️ MODO DESARROLLO LOCAL: Instalando paquetes .deb locales ---"
    
    LOCAL_DEBS_DIR="$ISO_DIR/../build/packages"
    if [ ! -d "$LOCAL_DEBS_DIR" ] || [ -z "$(ls "$LOCAL_DEBS_DIR"/*.deb 2>/dev/null)" ]; then
         # Fallback en caso de estar ejecutando dentro de la estructura de repo ISO
         LOCAL_DEBS_DIR="$ISO_DIR/build/packages"
    fi
    
    if [ ! -d "$LOCAL_DEBS_DIR" ] || [ -z "$(ls "$LOCAL_DEBS_DIR"/*.deb 2>/dev/null)" ]; then
        echo "❌ Error: No se encontraron paquetes .deb locales en $LOCAL_DEBS_DIR."
        echo "Ejecuta primero el empaquetador en la carpeta PKG/."
        exit 1
    fi
    
    # Copiar de forma segura debs al chroot temporal
    pkexec mkdir -p "$ROOTFS_TARGET/tmp/packages"
    pkexec cp "$LOCAL_DEBS_DIR"/*.deb "$ROOTFS_TARGET/tmp/packages/"
    
    # Instalar paquetes locales directamente y resolver dependencias
    pkexec /usr/sbin/chroot "$ROOTFS_TARGET" /bin/bash -c "
        apt-get update
        apt-get install -y --fix-broken /tmp/packages/*.deb
        apt-get clean
    "
    # Limpiar instaladores temporales
    pkexec rm -rf "$ROOTFS_TARGET/tmp/packages"
    echo "✅ Paquetes locales de Pulsar OS instalados correctamente."
else
    echo "--- 🌐 MODO PRODUCCIÓN: Añadiendo repositorio APT de Inled e instalando paquetes ---"
    
    # 1. Configurar clave GPG e inyectarla en el chroot
    pkexec /usr/sbin/chroot "$ROOTFS_TARGET" /bin/bash -c "
        apt-get update && apt-get install -y wget gnupg ca-certificates
        wget -qO- https://apt.inled.es/archive.key | gpg --dearmor | tee /usr/share/keyrings/inled-archive-keyring.gpg > /dev/null
    "
    
    # 2. Agregar repositorio APT a las fuentes
    echo "deb [signed-by=/usr/share/keyrings/inled-archive-keyring.gpg] https://apt.inled.es stable main" | \
        pkexec tee "$ROOTFS_TARGET/etc/apt/sources.list.d/inled.list" > /dev/null
        
    # 3. Actualizar e instalar el metapaquete o paquetes específicos
    echo "Instalando paquetes declarativos de Pulsar OS..."
    pkexec /usr/sbin/chroot "$ROOTFS_TARGET" /bin/bash -c "
        apt-get update
        apt-get install -y --no-install-recommends \
            pulsaros-branding \
            pulsaros-theme \
            pulsaros-gnome \
            pulsaros-sddm \
            pulsaros-plymouth \
            pulsaros-grub \
            pulsaros-calamares \
            pulsaros-essential
        apt-get clean
    "
    echo "✅ Paquetes de Pulsar OS instalados desde repositorio APT."
fi

# ==============================================================================
# FASE 5: Tareas Finales del Sistema (Generación de Kernel y Limpieza)
# ==============================================================================

echo "--- 🔄 Finalizando y actualizando initramfs ---"
pkexec /usr/sbin/chroot "$ROOTFS_TARGET" /bin/bash -c "
    # Asegurar que el initramfs esté totalmente actualizado con los módulos
    update-initramfs -u -k all
"

echo "✨ Proceso finalizado con éxito total. El rootfs limpio de Pulsar OS está en: $ROOTFS_TARGET"
echo "Para probar el resultado en QEMU, ejecuta: ./run-qemu.sh"
