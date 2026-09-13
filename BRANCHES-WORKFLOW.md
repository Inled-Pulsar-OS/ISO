# 💿 Canales de Compilación de ISOs: `stable` vs `unstable`

Pulsar OS permite compilar imágenes ISO tanto para el canal **`stable`** como para el canal **`unstable`**.

---

## 🏷️ Nombres de Archivo de las Imágenes

Las imágenes generadas incluyen explícitamente el canal en su nombre para que sean fáciles de identificar:

### Canal Stable:
- `pulsaros-stable-debian-grub-0.3-beta.iso`
- `pulsaros-stable-debian-refind-0.3-beta.iso`
- `pulsaros-stable-arch-grub-0.3-beta.iso`
- `pulsaros-stable-arch-refind-0.3-beta.iso`

### Canal Unstable:
- `pulsaros-unstable-debian-grub-0.3-beta.iso`
- `pulsaros-unstable-debian-refind-0.3-beta.iso`
- `pulsaros-unstable-arch-grub-0.3-beta.iso`
- `pulsaros-unstable-arch-refind-0.3-beta.iso`

---

## ⚙️ Diferencias Técnicas entre Canales

| Característica | Canal `stable` | Canal `unstable` |
|---|---|---|
| **Base Debian** | Debian 13 (Trixie) | Debian Testing / Sid |
| **Repositorio APT** | `https://apt.inled.es stable main` | `https://apt.inled.es unstable main` |
| **Repositorio Arch (Pacman)** | `https://apt.inled.es/arch/stable/$arch` | `https://apt.inled.es/arch/unstable/$arch` |
| **Propósito** | Imágenes de producción y versiones públicas oficiales | Imágenes de pruebas, integración continua e iteración rápida |

---

## 🔨 Cómo Compilar

### 1. Desde GitHub Actions
1. Ve al workflow **Build and Release ISO**.
2. Selecciona **Run workflow**.
3. En el selector **Branch to build**, elige `stable` o `unstable`.
4. El sistema compilará las 4 ediciones y las publicará con el nombre y los enlaces correspondientes en SourceForge y en el Internet Recovery Manifest (`releases.json`).

### 2. Desde la Línea de Comandos (Local)

```bash
# Compilar una ISO Unstable (Debian + rEFInd)
sudo ./build-iso.sh --debian --refind --minimal --branch unstable --version "0.3-beta"

# Compilar una ISO Stable oficial (Arch + GRUB)
sudo ./build-iso.sh --arch --grub --minimal --branch stable --version "0.3-beta"

# Compilar todas las ISOs en paralelo para unstable
sudo ./build-parallel.sh --all --minimal --branch unstable --version "0.3-beta"
```

---

## 🛟 Entorno de Recuperación Live (Debian Recovery & Bootloader Repair)

Cada imagen Live ISO (tanto las basadas en **Debian** como en **Arch Linux**, y con **GRUB** o **rEFInd**) incluye ahora una entrada en el menú de arranque:

**`Pulsar OS Recovery (Emergency & Bootloader Repair)`**

### ¿Para qué sirve?
- **Reparación de cargadores de arranque rotos**: Permite reinstalar o regenerar GRUB (`grub-install`), rEFInd o reparar entradas EFI con `efibootmgr`.
- **Acceso `chroot` instantáneo**: Incluye `arch-install-scripts` (`arch-chroot`) para montar y entrar en cualquier instalación dañada de Pulsar OS con un solo comando.
- **Herramientas de disco**: `gparted`, `parted`, `fdisk`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, `ntfs-3g`.
- **Time Machine Recovery**: Permite restaurar copias de seguridad de Time Machine (Btrfs snapshots / Restic) directamente desde el entorno live sin tocar la partición principal.
- **Terminal con permisos root completos**: Para diagnósticos de emergencia y rescate del sistema.
