#!/bin/bash
# ==============================================================================
# Pulsar OS - Parallel ISO Builder (Safe & Thermally Balanced)
# ==============================================================================
# Compila múltiples ediciones de Pulsar OS en paralelo (ej. Debian y Arch Linux)
# protegiendo el sistema de sobrecalentamiento y evitando colisiones de archivos.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Auto-elevación con sudo si no es root
if [ "$EUID" -ne 0 ]; then
    echo "🔒 Elevando privilegios con sudo para la compilación paralela..."
    exec sudo "$0" "$@"
fi

# Argumentos por defecto
BUILD_DEBIAN=true
BUILD_ARCH=true
EXTRA_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --debian-only)
            BUILD_DEBIAN=true
            BUILD_ARCH=false
            ;;
        --arch-only)
            BUILD_DEBIAN=false
            BUILD_ARCH=true
            ;;
        *)
            EXTRA_ARGS+=("$arg")
            ;;
    esac
done

echo "======================================================================"
echo "🚀 Pulsar OS - Compilación Paralela Inteligente"
echo "======================================================================"
echo "🔧 Debian build: $BUILD_DEBIAN"
echo "🔧 Arch build:   $BUILD_ARCH"
echo "⚙️  Opciones extra: ${EXTRA_ARGS[*]:-ninguna}"
echo "======================================================================"

# 1. Compilación previa de paquetes locales (si aplica) para evitar colisiones
if [ -d "$SCRIPT_DIR/../PKG" ]; then
    echo "📦 Preparando y compilando paquetes locales previos..."
    if $BUILD_DEBIAN && [ -f "$SCRIPT_DIR/../PKG/package-and-deploy.sh" ]; then
        echo "   🔨 Compilando paquetes Debian (.deb)..."
        (cd "$SCRIPT_DIR/../PKG" && ./package-and-deploy.sh all --incremental || true)
    fi
    if $BUILD_ARCH && [ -f "$SCRIPT_DIR/../PKG/arch/package-and-deploy.sh" ]; then
        echo "   🔨 Compilando paquetes Arch Linux (.pkg.tar.zst)..."
        (cd "$SCRIPT_DIR/../PKG/arch" && ./package-and-deploy.sh all --incremental || true)
    fi
fi

mkdir -p "$SCRIPT_DIR/build/logs"
LOG_DEBIAN="$SCRIPT_DIR/build/logs/build-debian-$(date +%Y%m%d_%H%M%S).log"
LOG_ARCH="$SCRIPT_DIR/build/logs/build-arch-$(date +%Y%m%d_%H%M%S).log"

PIDS=()
NAMES=()

# Función para ejecutar build con etiqueta y registro
run_build() {
    local name="$1"
    local log_file="$2"
    local color="$3"
    shift 3
    local reset="\033[0m"

    echo -e "${color}[$name]${reset} Iniciando compilación... (Log: $log_file)"
    "$@" >> "$log_file" 2>&1
}

# 2. Lanzar builds en paralelo
if $BUILD_DEBIAN; then
    run_build "Debian" "$LOG_DEBIAN" "\033[1;34m" ./build-iso.sh --debian --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
    NAMES+=("Debian")
fi

if $BUILD_ARCH; then
    run_build "Arch" "$LOG_ARCH" "\033[1;36m" ./build-iso.sh --arch --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
    NAMES+=("Arch")
fi

echo "⏳ Compilaciones en ejecución en segundo plano. Monitorizando..."
FAIL=0

for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    name="${NAMES[$i]}"
    if wait "$pid"; then
        echo -e "\033[1;32m✅ [$name] Compilación completada con éxito.\033[0m"
    else
        echo -e "\033[1;31m❌ [$name] Falló la compilación. Revisa el log correspondiente en $SCRIPT_DIR/build/logs/\033[0m"
        FAIL=1
    fi
done

echo "======================================================================"
if [ $FAIL -eq 0 ]; then
    echo -e "\033[1;32m🎉 ¡Todas las imágenes ISO se han generado correctamente!\033[0m"
    ls -lh "$SCRIPT_DIR/build"/*.iso 2>/dev/null || true
else
    echo -e "\033[1;31m⚠️  Una o más compilaciones terminaron con errores.\033[0m"
    exit 1
fi
echo "======================================================================"
