#!/bin/bash
# ==============================================================================
# Pulsar OS - Parallel ISO Builder (Safe, Fast & Concurrency-Protected)
# ==============================================================================
# Compila múltiples ediciones de Pulsar OS en paralelo:
#   - Arch Linux (GRUB)
#   - Arch Linux (rEFInd)
#   - Debian (GRUB)
#   - Debian (rEFInd)
#
# Protege el sistema de sobrecalentamiento, aísla los puntos de montaje chroot
# y evita colisiones en la creación de imágenes y sistemas de archivos.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
cd "$SCRIPT_DIR"

# Manejar ayuda antes de auto-elevación
for arg in "$@"; do
    if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
        cat << 'EOF'
==============================================================================
🚀 Pulsar OS - Compilador de ISOs en Paralelo
==============================================================================
Uso:
  sudo ./build-parallel.sh [OBJETIVOS] [OPCIONES]

Objetivos específicos:
  --all                 Construye todas las variantes (Arch GRUB, Arch rEFInd, Debian GRUB, Debian rEFInd) [Por defecto]
  --arch-grub           Construye la edición Arch Linux con GRUB
  --arch-refind         Construye la edición Arch Linux con rEFInd
  --debian-grub         Construye la edición Debian con GRUB
  --debian-refind       Construye la edición Debian con rEFInd

Filtros de objetivos:
  --arch | --arch-only      Compila únicamente ediciones de Arch Linux (GRUB y rEFInd)
  --debian | --debian-only  Compila únicamente ediciones de Debian (GRUB y rEFInd)
  --grub | --grub-only      Compila únicamente ediciones con GRUB (Arch y Debian)
  --refind | --refind-only  Compila únicamente ediciones con rEFInd (Arch y Debian)

Opciones adicionales (se pasan a cada build):
  --minimal             Compilación mínima optimizada (~2-3GB)
  --full                Compilación estándar completa
  --clean-base          Elimina y reconstruye desde cero la caché base
  --nvidia              Incluye controladores propietarios NVIDIA y Broadcom
  --branch, -b <rama>   Rama de compilación: stable, forky, rolling (def: stable)
  --version, -v <ver>   Etiqueta de versión para las ISOs
  --incremental, -i     Recompilación incremental de paquetes locales
  --skip-pkg            Omite la fase de compilación de paquetes de /PKG
  --production          Usa repositorios remotos en vez de paquetes locales
  --help, -h            Muestra este mensaje de ayuda

Ejemplos:
  sudo ./build-parallel.sh --all
  sudo ./build-parallel.sh --arch-grub --arch-refind --debian-grub
  sudo ./build-parallel.sh --arch --minimal
  sudo ./build-parallel.sh --refind
==============================================================================
EOF
        exit 0
    fi
done

# Auto-elevación con sudo si no es root
if [ "$EUID" -ne 0 ]; then
    echo "🔒 Elevando privilegios con sudo para la compilación paralela..."
    exec sudo "$SCRIPT_PATH" "$@"
fi

# ==============================================================================
# Ayuda / Usage
# ==============================================================================
show_help() {
    cat << 'EOF'
==============================================================================
🚀 Pulsar OS - Compilador de ISOs en Paralelo
==============================================================================
Uso:
  sudo ./build-parallel.sh [OBJETIVOS] [OPCIONES]

Objetivos específicos:
  --all                 Construye todas las variantes (Arch GRUB, Arch rEFInd, Debian GRUB, Debian rEFInd) [Por defecto]
  --arch-grub           Construye la edición Arch Linux con GRUB
  --arch-refind         Construye la edición Arch Linux con rEFInd
  --debian-grub         Construye la edición Debian con GRUB
  --debian-refind       Construye la edición Debian con rEFInd

Filtros de objetivos:
  --arch | --arch-only      Compila únicamente ediciones de Arch Linux (GRUB y rEFInd)
  --debian | --debian-only  Compila únicamente ediciones de Debian (GRUB y rEFInd)
  --grub | --grub-only      Compila únicamente ediciones con GRUB (Arch y Debian)
  --refind | --refind-only  Compila únicamente ediciones con rEFInd (Arch y Debian)

Opciones adicionales (se pasan a cada build):
  --minimal             Compilación mínima optimizada (~2-3GB)
  --full                Compilación estándar completa
  --clean-base          Elimina y reconstruye desde cero la caché base
  --nvidia              Incluye controladores propietarios NVIDIA y Broadcom
  --branch, -b <rama>   Rama de compilación: stable, forky, rolling (def: stable)
  --version, -v <ver>   Etiqueta de versión para las ISOs
  --incremental, -i     Recompilación incremental de paquetes locales
  --skip-pkg            Omite la fase de compilación de paquetes de /PKG
  --production          Usa repositorios remotos en vez de paquetes locales
  --help, -h            Muestra este mensaje de ayuda

Ejemplos:
  sudo ./build-parallel.sh --all
  sudo ./build-parallel.sh --arch-grub --arch-refind --debian-grub
  sudo ./build-parallel.sh --arch --minimal
  sudo ./build-parallel.sh --refind
==============================================================================
EOF
    exit 0
}

# ==============================================================================
# Parse Arguments / Procesar Argumentos
# ==============================================================================
TARGET_ARCH_GRUB=false
TARGET_ARCH_REFIND=false
TARGET_DEBIAN_GRUB=false
TARGET_DEBIAN_REFIND=false

EXPLICIT_SPECIFIC_TARGET=false
FILTER_ARCH=false
FILTER_DEBIAN=false
FILTER_GRUB=false
FILTER_REFIND=false

SKIP_PKG=false
INCREMENTAL_PKG=true
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            ;;
        --all)
            TARGET_ARCH_GRUB=true
            TARGET_ARCH_REFIND=true
            TARGET_DEBIAN_GRUB=true
            TARGET_DEBIAN_REFIND=true
            EXPLICIT_SPECIFIC_TARGET=true
            shift
            ;;
        --arch-grub)
            TARGET_ARCH_GRUB=true
            EXPLICIT_SPECIFIC_TARGET=true
            shift
            ;;
        --arch-refind)
            TARGET_ARCH_REFIND=true
            EXPLICIT_SPECIFIC_TARGET=true
            shift
            ;;
        --debian-grub)
            TARGET_DEBIAN_GRUB=true
            EXPLICIT_SPECIFIC_TARGET=true
            shift
            ;;
        --debian-refind)
            TARGET_DEBIAN_REFIND=true
            EXPLICIT_SPECIFIC_TARGET=true
            shift
            ;;
        --arch|--arch-only)
            FILTER_ARCH=true
            shift
            ;;
        --debian|--debian-only)
            FILTER_DEBIAN=true
            shift
            ;;
        --grub|--grub-only)
            FILTER_GRUB=true
            shift
            ;;
        --refind|--refind-only)
            FILTER_REFIND=true
            shift
            ;;
        --skip-pkg|--skip-all|--pack-only|--skip-build)
            SKIP_PKG=true
            shift
            ;;
        --incremental|-i|--smart)
            INCREMENTAL_PKG=true
            shift
            ;;
        --clean-base|--nvidia|--minimal|--full|--production|--remote|--local)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        --branch|-b|--version|-v)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# Si no se definieron targets específicos, resolver mediante filtros o valores por defecto
if [ "$EXPLICIT_SPECIFIC_TARGET" = false ]; then
    # Determinar distros activas
    USE_ARCH=false
    USE_DEBIAN=false
    if $FILTER_ARCH && ! $FILTER_DEBIAN; then
        USE_ARCH=true
    elif $FILTER_DEBIAN && ! $FILTER_ARCH; then
        USE_DEBIAN=true
    else
        USE_ARCH=true
        USE_DEBIAN=true
    fi

    # Determinar bootloaders activos
    USE_GRUB=false
    USE_REFIND=false
    if $FILTER_GRUB && ! $FILTER_REFIND; then
        USE_GRUB=true
    elif $FILTER_REFIND && ! $FILTER_GRUB; then
        USE_REFIND=true
    else
        USE_GRUB=true
        USE_REFIND=true
    fi

    # Asignar objetivos según la combinación
    if $USE_ARCH && $USE_GRUB; then TARGET_ARCH_GRUB=true; fi
    if $USE_ARCH && $USE_REFIND; then TARGET_ARCH_REFIND=true; fi
    if $USE_DEBIAN && $USE_GRUB; then TARGET_DEBIAN_GRUB=true; fi
    if $USE_DEBIAN && $USE_REFIND; then TARGET_DEBIAN_REFIND=true; fi
fi

# Comprobar que al menos un objetivo esté seleccionado
if ! $TARGET_ARCH_GRUB && ! $TARGET_ARCH_REFIND && ! $TARGET_DEBIAN_GRUB && ! $TARGET_DEBIAN_REFIND; then
    echo "❌ Error: No se ha seleccionado ningún objetivo de compilación válido."
    exit 1
fi

NEED_DEBIAN_PKGS=false
if $TARGET_DEBIAN_GRUB || $TARGET_DEBIAN_REFIND; then
    NEED_DEBIAN_PKGS=true
fi

NEED_ARCH_PKGS=false
if $TARGET_ARCH_GRUB || $TARGET_ARCH_REFIND; then
    NEED_ARCH_PKGS=true
fi

echo "======================================================================"
echo "🚀 Pulsar OS - Compilación Paralela Inteligente"
echo "======================================================================"
echo "🎯 Objetivos seleccionados:"
echo "   🔹 Arch Linux (GRUB):    $TARGET_ARCH_GRUB"
echo "   🔹 Arch Linux (rEFInd):  $TARGET_ARCH_REFIND"
echo "   🔹 Debian (GRUB):        $TARGET_DEBIAN_GRUB"
echo "   🔹 Debian (rEFInd):      $TARGET_DEBIAN_REFIND"
echo "⚙️  Opciones adicionales:    ${EXTRA_ARGS[*]:-ninguna}"
echo "======================================================================"

# ==============================================================================
# FASE PREVIA: Limpieza profunda y liberación de montajes residuales
# ==============================================================================
echo "🧹 Liberando y desmontando recursos residuales previos..."

# Desactivar posibles swapfiles residuales en cualquier subdirectorio de build
find "$SCRIPT_DIR/build" -name "swapfile" -exec swapoff {} + 2>/dev/null || true

# Desmontar de forma segura todos los puntos de montaje vinculados bajo $SCRIPT_DIR/build
if [ -r /proc/self/mounts ]; then
    awk '$2 ~ "^'"$SCRIPT_DIR/build"'/" || $2 == "'"$SCRIPT_DIR/build"'" {print $2}' /proc/self/mounts 2>/dev/null | sort -r | while read -r mp; do
        echo "   🔌 Desmontando montaje residual: $mp"
        umount -l "$mp" 2>/dev/null || true
    done
fi

# Restaurar nodos críticos del sistema (/dev/ptmx, /dev/kvm) por si sufrieron daños
chmod 666 /dev/pts/ptmx 2>/dev/null || true
if [ ! -c /dev/ptmx ]; then
    rm -f /dev/ptmx 2>/dev/null || true
    mknod -m 666 /dev/ptmx c 5 2 2>/dev/null || true
fi
chmod 666 /dev/ptmx 2>/dev/null || true

if [ -e /dev/kvm ]; then
    chmod 666 /dev/kvm 2>/dev/null || true
    chown root:kvm /dev/kvm 2>/dev/null || true
fi

echo "✅ Entorno de compilación limpio y libre de bloqueos."

# ==============================================================================
# FASE 1: Pre-compilación de paquetes locales y entorno Recovery
# ==============================================================================
if [ -d "$SCRIPT_DIR/../PKG" ] && [ "$SKIP_PKG" = false ]; then
    echo "📦 Preparando y compilando paquetes locales previos..."
    INC_PARAM=""
    if [ "$INCREMENTAL_PKG" = true ]; then
        INC_PARAM="--incremental"
    fi

    if $NEED_DEBIAN_PKGS && [ -f "$SCRIPT_DIR/../PKG/package-and-deploy.sh" ]; then
        echo "   🔨 [Debian] Compilando paquetes .deb locales..."
        (cd "$SCRIPT_DIR/../PKG" && ./package-and-deploy.sh all $INC_PARAM || true)
    fi

    if $NEED_ARCH_PKGS && [ -f "$SCRIPT_DIR/../PKG/arch/package-and-deploy.sh" ]; then
        echo "   🔨 [Arch] Compilando paquetes .pkg.tar.zst locales..."
        (cd "$SCRIPT_DIR/../PKG/arch" && ./package-and-deploy.sh all $INC_PARAM || true)
    fi
fi

# Pre-generar el entorno de recovery dedicado de Debian si no existe
REC_OUT="$SCRIPT_DIR/build/recovery-out"
if [ -f "$SCRIPT_DIR/build-recovery-image.sh" ] && [ ! -f "$REC_OUT/filesystem.squashfs" ]; then
    echo "🛠️  Pre-generando imagen de recuperación compartida (Debian Recovery)..."
    bash "$SCRIPT_DIR/build-recovery-image.sh" || echo "⚠️ Notice: Recovery build finished with warnings, continuing..."
fi

# ==============================================================================
# FASE 2: Lanzamiento de compilaciones en paralelo
# ==============================================================================
mkdir -p "$SCRIPT_DIR/build/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

PIDS=()
NAMES=()
COLORS=()
LOGS=()
START_TIMES=()

run_build_worker() {
    local name="$1"
    local color="$2"
    local log_file="$3"
    shift 3
    local reset="\033[0m"

    echo -e "${color}▶️  [$name]${reset} Iniciando compilación en paralelo... (Log: $log_file)"
    "$@" >> "$log_file" 2>&1
}

# 1. Arch Linux GRUB
if $TARGET_ARCH_GRUB; then
    LOG="$SCRIPT_DIR/build/logs/build-arch-grub-${TIMESTAMP}.log"
    START_TIMES+=($(date +%s))
    NAMES+=("Arch (GRUB)")
    COLORS+=("\033[1;36m") # Cyan
    LOGS+=("$LOG")
    run_build_worker "Arch (GRUB)" "\033[1;36m" "$LOG" "$SCRIPT_DIR/build-iso.sh" --arch --grub --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
fi

# 2. Arch Linux rEFInd
if $TARGET_ARCH_REFIND; then
    LOG="$SCRIPT_DIR/build/logs/build-arch-refind-${TIMESTAMP}.log"
    START_TIMES+=($(date +%s))
    NAMES+=("Arch (rEFInd)")
    COLORS+=("\033[1;34m") # Blue
    LOGS+=("$LOG")
    run_build_worker "Arch (rEFInd)" "\033[1;34m" "$LOG" "$SCRIPT_DIR/build-iso.sh" --arch --refind --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
fi

# 3. Debian GRUB
if $TARGET_DEBIAN_GRUB; then
    LOG="$SCRIPT_DIR/build/logs/build-debian-grub-${TIMESTAMP}.log"
    START_TIMES+=($(date +%s))
    NAMES+=("Debian (GRUB)")
    COLORS+=("\033[1;35m") # Magenta
    LOGS+=("$LOG")
    run_build_worker "Debian (GRUB)" "\033[1;35m" "$LOG" "$SCRIPT_DIR/build-iso.sh" --debian --grub --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
fi

# 4. Debian rEFInd
if $TARGET_DEBIAN_REFIND; then
    LOG="$SCRIPT_DIR/build/logs/build-debian-refind-${TIMESTAMP}.log"
    START_TIMES+=($(date +%s))
    NAMES+=("Debian (rEFInd)")
    COLORS+=("\033[1;33m") # Yellow
    LOGS+=("$LOG")
    run_build_worker "Debian (rEFInd)" "\033[1;33m" "$LOG" "$SCRIPT_DIR/build-iso.sh" --debian --refind --skip-pkg "${EXTRA_ARGS[@]}" &
    PIDS+=($!)
fi

echo ""
echo "⏳ ${#PIDS[@]} compilaciones en ejecución en segundo plano. Monitorizando progreso..."
echo ""

# Handle graceful exit on Ctrl+C / kill child workers
trap 'echo -e "\n🛑 Interrupción recibida. Cancelando compilaciones en segundo plano..."; kill "${PIDS[@]}" 2>/dev/null || true; exit 130' INT TERM

# ==============================================================================
# FASE 3: Monitorización en tiempo real y espera
# ==============================================================================
STATUS_DONE=()
STATUS_SUCCESS=()
for i in "${!PIDS[@]}"; do
    STATUS_DONE+=(false)
    STATUS_SUCCESS+=(false)
done

ACTIVE_COUNT=${#PIDS[@]}
TOTAL_COUNT=${#PIDS[@]}
reset="\033[0m"

while [ "$ACTIVE_COUNT" -gt 0 ]; do
    sleep 3
    echo -e "──────────────────────────────────────────────────────────────────────"
    for i in "${!PIDS[@]}"; do
        if [ "${STATUS_DONE[$i]}" = true ]; then
            continue
        fi

        pid="${PIDS[$i]}"
        name="${NAMES[$i]}"
        color="${COLORS[$i]}"
        log="${LOGS[$i]}"
        start_t="${START_TIMES[$i]}"
        curr_t=$(date +%s)
        dur=$((curr_t - start_t))
        dur_fmt=$(printf '%02dm %02ds' $((dur/60)) $((dur%60)))

        # Comprobar si el proceso ha finalizado
        if ! kill -0 "$pid" 2>/dev/null; then
            if wait "$pid"; then
                echo -e "${color}✅ [$name]${reset} \033[1;32mCompilación completada con éxito\033[0m (Duración: $dur_fmt)"
                STATUS_SUCCESS[$i]=true
            else
                echo -e "${color}❌ [$name]${reset} \033[1;31mFalló la compilación\033[0m (Duración: $dur_fmt)"
                echo "   📄 Log de errores: $log"
                echo "   🔻 Últimas líneas del registro de error:"
                tail -n 12 "$log" 2>/dev/null | sed 's/^/      │ /' || true
                STATUS_SUCCESS[$i]=false
            fi
            STATUS_DONE[$i]=true
            ACTIVE_COUNT=$((ACTIVE_COUNT - 1))
        else
            # Extraer el último paso relevante del log
            latest_step=$(grep -E '^(===|PHASE|[0-9]+%|📦|🔨|⚙️|🗜️|💿|✅|❌|---)' "$log" 2>/dev/null | tail -n 1 | sed 's/^[= -]*//' | cut -c 1-80)
            if [ -z "$latest_step" ]; then
                latest_step=$(tail -n 1 "$log" 2>/dev/null | cut -c 1-80)
            fi
            echo -e "${color}⏳ [$name]${reset} (${dur_fmt}) ➜ ${latest_step:-Procesando...}"
        fi
    done
done

# ==============================================================================
# Resumen Final
# ==============================================================================
FAIL=0
SUCCESS_COUNT=0
for i in "${!PIDS[@]}"; do
    if [ "${STATUS_SUCCESS[$i]}" = true ]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL=1
    fi
done

echo ""
echo "======================================================================"
if [ $FAIL -eq 0 ]; then
    echo -e "\033[1;32m🎉 ¡Todas las imágenes ISO ($SUCCESS_COUNT/$TOTAL_COUNT) se han generado correctamente!\033[0m"
else
    echo -e "\033[1;33m⚠️  Resumen: $SUCCESS_COUNT/$TOTAL_COUNT compilaciones completadas correctamente.\033[0m"
fi
echo "======================================================================"
echo "📂 Archivos ISO generados en $SCRIPT_DIR/build/:"
ls -lh "$SCRIPT_DIR/build"/*.iso 2>/dev/null || echo "   (No se encontraron archivos ISO)"
echo "======================================================================"

if [ $FAIL -ne 0 ]; then
    exit 1
fi
