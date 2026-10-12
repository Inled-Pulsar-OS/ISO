# Secure Boot assets / Assets de Secure Boot

Binarios y claves usados por `build-iso.sh` para arrancar las ISOs de Pulsar OS
con Secure Boot activo. Español debajo.

## Files / Archivos

| File | Origin / Origen | Purpose / Función |
|------|-----------------|--------------------|
| `shimx64.efi` | Debian, firmado por Microsoft | Primer stage: lo valida el firmware con las claves de Microsoft |
| `grubx64.efi` | Debian `grub-efi-amd64-signed` | GRUB firmado por "Debian Secure Boot CA" (cadena GRUB) |
| `mmx64.efi` | Debian shim | MokManager: interfaz para enrolar claves/hashes MOK |
| `pulsar-mok.crt` | Generada (`generate-mok.sh`) | Pública PEM: la usa `sbsign` para firmar binarios |
| `pulsar-mok.cer` | Generada (`generate-mok.sh`) | Pública DER: la enrola el usuario como MOK (formato obligatorio para MokManager) |
| `pulsar-mok.key` | Generada, NO commiteada | Privaada: firma rEFInd y kernels en la cadena rEFInd |

## How the chains work / Cómo funcionan las cadenas

- **GRUB ISO**: firmware -> `shimx64.efi` (firmado por Microsoft) -> `grubx64.efi`
  (GRUB firmado por Debian). El kernel lo carga GRUB por protocolo Linux, el
  firmware no lo verifica, así que no hace falta firmarlo.
- **rEFInd ISO**: firmware -> `bootx64.efi` (shim) -> `grubx64.efi` (rEFInd
  firmado con `pulsar-mok.key`). rEFInd carga los kernels como imagen EFI y el
  firmware verifica su firma, por eso el build firma `vmlinuz` y
  `vmlinuz-recovery` con la misma clave.

## One-time enrollment / Enrolado (una sola vez por máquina)

Con Secure Boot activo, al primer arranque de la ISO rEFInd (grabada con dd /
balenaEtcher) shim detecta que `grubx64.efi` no tiene la clave enrolada y abre
MokManager:

1. Elige **Enroll key from disk**.
2. Localiza `EFI/BOOT/refind.cer` (o `/EFI/BOOT/refind.cer` en la partición ESP).
3. Confirma (tecla `1` ver detalle, `0` enrolar) y elige **Reboot**.
4. Tras reiniciar, rEFInd arranca con Secure Boot activo.

En el sistema instalado: instala `pulsaros-refind` y ejecuta
`sudo pulsar-enroll-mok` (importa la MOK con `mokutil`; tras el reinicio,
MokManager muestra **Enroll MOK**).

## Key handling / Manejo de claves

La clave privada `pulsar-mok.key` está en `ISO/.gitignore`: nunca se commitea.
Regenérala con `./generate-mok.sh` o reutiliza la misma en todos los hosts de
build. Si la clave cambia, los usuarios deben re-enrolar la nueva `.cer`.