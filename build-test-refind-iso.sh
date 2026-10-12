#!/bin/bash
# ==============================================================================
# Pulsar OS - Standalone Lightweight rEFInd Test ISO Builder
# ==============================================================================
set -e

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
OUTPUT_ISO="$SCRIPT_DIR/pulsaros-refind-test.iso"
STAGING_DIR="/tmp/pulsaros-refind-iso-staging"
EFI_IMG="/tmp/refind-test-efi.img"

echo "🎨 Preparando tema e iconos rEFInd..."
bash "$SCRIPT_DIR/../PKG/pulsaros-refind/prepare-assets.sh" "/tmp/refind-pkg-staging"

rm -rf "$STAGING_DIR" "$EFI_IMG" "$OUTPUT_ISO"
mkdir -p "$STAGING_DIR/EFI/BOOT/themes"

# Copiar ejecutable EFI de rEFInd
REFIND_EFI="/usr/share/refind/refind_x64.efi"
if [ ! -f "$REFIND_EFI" ]; then
    REFIND_EFI="$(find /usr -name 'refind_x64.efi' 2>/dev/null | head -1)"
fi

if [ -z "$REFIND_EFI" ] || [ ! -f "$REFIND_EFI" ]; then
    echo "❌ No se encontró refind_x64.efi. Asegúrate de que refind esté instalado."
    exit 1
fi

cp -f "$REFIND_EFI" "$STAGING_DIR/EFI/BOOT/bootx64.efi"
cp -rf "/tmp/refind-pkg-staging/usr/share/refind/themes/rEFInd-Regular-Dark" "$STAGING_DIR/EFI/BOOT/themes/"

# Crear configuración de prueba de rEFInd con entradas simuladas de ejemplo
cat <<'EOF' > "$STAGING_DIR/EFI/BOOT/refind.conf"
timeout 0
enable_mouse
mouse_speed 4
mouse_size 16
resolution max
scanfor manual
dont_scan_dirs EFI,themes
dont_scan_files *
default_selection 1
include themes/rEFInd-Regular-Dark/theme.conf

menuentry "Pulsar OS" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_normal.png
    loader /EFI/BOOT/bootx64.efi
}

menuentry "Pulsar OS Live (RAM)" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_pulsaros_toram.png
    loader /EFI/BOOT/bootx64.efi
}

menuentry "Pulsar OS Recovery" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_recovery.png
    loader /EFI/BOOT/bootx64.efi
}

menuentry "Windows Boot Manager" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_win.png
    loader /EFI/BOOT/bootx64.efi
}

menuentry "Arch Linux" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_arch.png
    loader /EFI/BOOT/bootx64.efi
}

menuentry "Ubuntu" {
    icon /EFI/BOOT/themes/rEFInd-Regular-Dark/icons/os_ubuntu.png
    loader /EFI/BOOT/bootx64.efi
}
EOF

# Crear efi.img partición FAT de arranque
echo "📦 Creando imagen EFI FAT..."
truncate -s 32M "$EFI_IMG"
mkfs.vfat -F 16 "$EFI_IMG" >/dev/null

mmd -i "$EFI_IMG" ::/EFI
mmd -i "$EFI_IMG" ::/EFI/BOOT
mcopy -s -i "$EFI_IMG" "$STAGING_DIR/EFI/BOOT"/* ::/EFI/BOOT/

# Generar ISO híbrida UEFI con xorriso
echo "💿 Creando ISO con xorriso..."
xorriso -return_with "WARNING" 0 \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "PULSAR_REFIND_TEST" \
    -eltorito-alt-boot \
    -e EFI/BOOT/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$OUTPUT_ISO" \
    -graft-points \
    /="$STAGING_DIR" \
    /EFI/BOOT/efi.img="$EFI_IMG"

rm -rf "$STAGING_DIR" "$EFI_IMG" "/tmp/refind-pkg-staging"

echo ""
echo "✅ ISO ligera de prueba de rEFInd generada con éxito en:"
echo "   $OUTPUT_ISO"
echo ""
echo "Para probarla en QEMU ejecuta:"
echo "   ./ISO/run-qemu.sh $OUTPUT_ISO"
