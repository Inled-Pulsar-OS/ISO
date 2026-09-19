#!/usr/bin/env bash
# ==============================================================================
# Tube OS - QEMU Virtual Machine Runner
# Supports ISO boot, Disk boot, UEFI NVRAM persistence, and Network Tunneling
# ==============================================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${BASE_DIR}/build" ]]; then
    BUILD_DIR="${BASE_DIR}/build"
elif [[ -d "${BASE_DIR}/ISO/build" ]]; then
    BUILD_DIR="${BASE_DIR}/ISO/build"
else
    BUILD_DIR="${BASE_DIR}/build"
fi
DISK_IMAGE="${BUILD_DIR}/tubeos-disk.qcow2"
VARS_IMAGE="${BUILD_DIR}/OVMF_VARS.fd"

# Defaults
BOOT_MODE="iso" # "iso" or "disk"
DISTRO="arch"   # "arch" or "debian"
MEM="4G"
SMP="4"
DISK_SIZE="25G"
RESET_DISK=false
HEADLESS=false
HTTP_PORT="8088"
MIGRATE_PORT="8070"
SSH_PORT="2222"
CUSTOM_ISO_PATH=""

# Color formatting
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --iso              Boot from Tube OS Live ISO (default mode, disk also attached)
  --disk             Boot directly from installed virtual disk
  --arch             Boot Tube OS Arch Linux ISO (default distro)
  --debian           Boot Tube OS Debian ISO
  --distro <distro>  Select distro: 'arch' or 'debian' (default: arch)
  --reset-disk       Re-create virtual disk (${DISK_IMAGE})
  --disk-size <size> Virtual disk size (default: 25G)
  --mem <size>       RAM allocated to VM (default: 4G)
  --smp <cores>      Number of CPU cores (default: 4)
  --iso-path <path>  Custom ISO path
  --port <port>      Host port for Web UI (guest:80) (default: 8088)
  --passthrough      Enable bridge network on virbr0 for LAN mDNS access (http://tubeos.local)
  --headless         Run in headless mode (no GUI window)
  -h, --help         Show this help message

Port forwardings active in VM:
  Host ${HTTP_PORT}   -> Guest 80   (Tube OS Web Installer / CasaOS)
  Host ${MIGRATE_PORT}   -> Guest 8070 (DockerMigrate)
  Host ${SSH_PORT}   -> Guest 22   (SSH)

Examples:
  $(basename "$0") --iso --arch           # Boot Arch ISO
  $(basename "$0") --iso --debian         # Boot Debian ISO
  $(basename "$0") --disk                 # Boot installed system from virtual disk
  $(basename "$0") --reset-disk --iso     # Re-create empty disk and boot ISO
EOF
    exit 0
}

NET_MODE="user" # "user" or "bridge"

# Parse CLI Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            BOOT_MODE="iso"
            shift
            ;;
        --disk)
            BOOT_MODE="disk"
            shift
            ;;
        --arch|--archlinux)
            DISTRO="arch"
            shift
            ;;
        --debian)
            DISTRO="debian"
            shift
            ;;
        --distro)
            DISTRO="$2"
            shift 2
            ;;
        --reset-disk)
            RESET_DISK=true
            shift
            ;;
        --passthrough|--bridge|--tap)
            NET_MODE="bridge"
            shift
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --mem)
            MEM="$2"
            shift 2
            ;;
        --smp)
            SMP="$2"
            shift 2
            ;;
        --iso-path)
            CUSTOM_ISO_PATH="$2"
            shift 2
            ;;
        --port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            ;;
    esac
done

mkdir -p "${BUILD_DIR}"

# Determine ISO File
if [[ -n "${CUSTOM_ISO_PATH}" ]]; then
    ISO_FILE="${CUSTOM_ISO_PATH}"
else
    ISO_FILE="${BUILD_DIR}/tubeos-stable-${DISTRO}-grub.iso"
    # Auto fallback if chosen distro iso is missing but the other exists
    if [[ ! -f "${ISO_FILE}" ]]; then
        if [[ "${DISTRO}" == "arch" ]] && [[ -f "${BUILD_DIR}/tubeos-stable-debian-grub.iso" ]]; then
            echo -e "${YELLOW}Note: Arch ISO not found, falling back to Debian ISO.${NC}"
            ISO_FILE="${BUILD_DIR}/tubeos-stable-debian-grub.iso"
            DISTRO="debian"
        elif [[ "${DISTRO}" == "debian" ]] && [[ -f "${BUILD_DIR}/tubeos-stable-arch-grub.iso" ]]; then
            echo -e "${YELLOW}Note: Debian ISO not found, falling back to Arch ISO.${NC}"
            ISO_FILE="${BUILD_DIR}/tubeos-stable-arch-grub.iso"
            DISTRO="arch"
        fi
    fi
fi

# 1. Prepare Virtual Disk
if [[ "${RESET_DISK}" == true ]] || [[ ! -f "${DISK_IMAGE}" ]]; then
    echo -e "${CYAN}>>> Creating fresh virtual disk: ${DISK_IMAGE} (${DISK_SIZE})${NC}"
    rm -f "${DISK_IMAGE}"
    qemu-img create -f qcow2 "${DISK_IMAGE}" "${DISK_SIZE}"
fi

# 2. Check & Prepare OVMF UEFI NVRAM
OVMF_CODE=""
if [[ -f "/usr/share/ovmf/x64/OVMF_CODE.4m.fd" ]]; then
    OVMF_CODE="/usr/share/ovmf/x64/OVMF_CODE.4m.fd"
    OVMF_VARS_SRC="/usr/share/ovmf/x64/OVMF_VARS.4m.fd"
elif [[ -f "/usr/share/ovmf/x64/OVMF_CODE.fd" ]]; then
    OVMF_CODE="/usr/share/ovmf/x64/OVMF_CODE.fd"
    OVMF_VARS_SRC="/usr/share/ovmf/x64/OVMF_VARS.fd"
elif [[ -f "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd" ]]; then
    OVMF_CODE="/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
    OVMF_VARS_SRC="/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
fi

if [[ "${RESET_DISK}" == true ]] || [[ ! -f "${VARS_IMAGE}" ]]; then
    if [[ -n "${OVMF_VARS_SRC:-}" ]] && [[ -f "${OVMF_VARS_SRC}" ]]; then
        echo -e "${CYAN}>>> Initializing UEFI NVRAM vars: ${VARS_IMAGE}${NC}"
        cp "${OVMF_VARS_SRC}" "${VARS_IMAGE}"
    fi
fi

# 3. Verify ISO presence if ISO boot
if [[ "${BOOT_MODE}" == "iso" ]]; then
    if [[ ! -f "${ISO_FILE}" ]]; then
        echo -e "${RED}Error: ISO file not found at ${ISO_FILE}${NC}"
        echo -e "${YELLOW}Please build the ISO first with: ./ISO/build-tubeos-iso.sh --${DISTRO} --local${NC}"
        exit 1
    fi
fi

# 4. KVM Acceleration
KVM_FLAGS=()
if [[ -e /dev/kvm ]] && [[ -w /dev/kvm ]]; then
    KVM_FLAGS=("-enable-kvm" "-cpu" "host")
else
    echo -e "${YELLOW}Warning: /dev/kvm not writable or available. Running with standard emulation.${NC}"
    KVM_FLAGS=("-cpu" "max")
fi

# 5. Assemble QEMU Command
QEMU_CMD=(
    qemu-system-x86_64
    "${KVM_FLAGS[@]}"
    -m "${MEM}"
    -smp "${SMP}"
    -vga virtio
)

# Network Configuration
if [[ "${NET_MODE}" == "bridge" ]]; then
    # Try to ensure bridge virbr0 is ready
    if ! ip link show virbr0 >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> Bridge virbr0 is not active. Attempting to start libvirt default network...${NC}"
        virsh -c qemu:///system net-start default >/dev/null 2>&1 || sudo virsh net-start default >/dev/null 2>&1 || true
    fi

    # Check bridge helper configuration
    if [[ -f "/usr/lib/qemu/qemu-bridge-helper" ]] && ip link show virbr0 >/dev/null 2>&1; then
        echo -e "${GREEN}>>> Network: Bridge Passthrough ACTIVE on virbr0${NC}"
        echo -e "    mDNS & Direct LAN active: ${CYAN}http://tubeos.local${NC}"
        echo -e "    DockerMigrate on LAN:     ${CYAN}http://tubeos.local:8070${NC}"
        # Single bridged NIC directly on virbr0 (avoids asymmetric routing collision)
        QEMU_CMD+=(
            -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
            -netdev "bridge,id=net0,br=virbr0,helper=/usr/lib/qemu/qemu-bridge-helper"
        )
    else
        echo -e "${YELLOW}>>> Bridge virbr0 not available. Falling back to clean User NAT mode.${NC}"
        NET_MODE="user"
    fi
fi

if [[ "${NET_MODE}" == "user" ]]; then
    echo -e "${CYAN}>>> Network: User NAT active with port forwarding${NC}"
    echo -e "    Web Interface: ${GREEN}http://localhost:${HTTP_PORT}${NC}"
    echo -e "    DockerMigrate: ${GREEN}http://localhost:${MIGRATE_PORT}${NC}"
    echo -e "    SSH:           ${GREEN}localhost:${SSH_PORT}${NC}"
    # Single User NAT NIC with clean port forwards
    QEMU_CMD+=(
        -device virtio-net-pci,netdev=net0
        -netdev "user,id=net0,hostname=tubeos,hostfwd=tcp::${HTTP_PORT}-:80,hostfwd=tcp::8070-:8070,hostfwd=tcp::${SSH_PORT}-:22"
    )
fi

# UEFI configuration
if [[ -n "${OVMF_CODE}" ]] && [[ -f "${VARS_IMAGE}" ]]; then
    QEMU_CMD+=(
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        -drive "if=pflash,format=raw,file=${VARS_IMAGE}"
    )
elif [[ -f "/usr/share/ovmf/x64/OVMF.4m.fd" ]]; then
    QEMU_CMD+=(-bios "/usr/share/ovmf/x64/OVMF.4m.fd")
fi

# Storage & Boot devices
if [[ "${BOOT_MODE}" == "iso" ]]; then
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  Starting Tube OS VM (Booting from ISO)     ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "  Web Installer: ${CYAN}http://localhost:${HTTP_PORT}${NC}"
    echo -e "  DockerMigrate: ${CYAN}http://localhost:${MIGRATE_PORT}${NC}"
    echo -e "  SSH Port:      ${CYAN}localhost:${SSH_PORT}${NC}"
    echo -e "  Virtual Disk:  ${DISK_IMAGE}"
    echo -e "  Live ISO:      ${ISO_FILE}"
    echo -e "${GREEN}=============================================${NC}"

    QEMU_CMD+=(
        -drive "file=${DISK_IMAGE},format=qcow2,if=virtio"
        -cdrom "${ISO_FILE}"
        -boot d
    )
else
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  Starting Tube OS VM (Booting from Disk)    ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "  Web Interface: ${CYAN}http://localhost:${HTTP_PORT}${NC}"
    echo -e "  DockerMigrate: ${CYAN}http://localhost:${MIGRATE_PORT}${NC}"
    echo -e "  SSH Port:      ${CYAN}localhost:${SSH_PORT}${NC}"
    echo -e "  Virtual Disk:  ${DISK_IMAGE}"
    echo -e "${GREEN}=============================================${NC}"

    QEMU_CMD+=(
        -drive "file=${DISK_IMAGE},format=qcow2,if=virtio"
        -boot c
    )
fi

if [[ "${HEADLESS}" == true ]]; then
    QEMU_CMD+=(-display none)
fi

# Execute QEMU
echo -e "${CYAN}Running:${NC} ${QEMU_CMD[*]}"
exec "${QEMU_CMD[@]}"
