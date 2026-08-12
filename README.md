# Pulsar OS ISO

This repository contains the ISO build script, the configuration files for preinstalled packages, and the Github Actions workflows.  
PulsarOS is built 100% by Github Actions, fully auditable end-to-end, and the ISO images are uploaded to Sourceforge (since Github Releases has very low size limits).

## Prerequisites

The build script checks for missing dependencies and tells you what to install. But if you want to set everything up beforehand:

### Arch Linux / CachyOS / Manjaro

```bash
sudo pacman -S --needed \
  arch-install-scripts squashfs-tools grub xorriso mtools dosfstools \
  binutils libisoburn sassc imagemagick psmisc \
  fakeroot rsync jq curl unzip wget git
```

### Debian / Ubuntu / Pop!_OS

```bash
sudo apt-get install -y \
  mmdebstrap squashfs-tools grub-common grub-efi-amd64-bin grub-pc-bin \
  xorriso mtools dosfstools binutils unzip sassc imagemagick psmisc \
  debian-archive-keyring rsync jq curl wget fakeroot git
```

### What each package does

| Package | Purpose |
|---------|---------|
| `arch-install-scripts` / `mmdebstrap` | Bootstrap the base chroot (pacstrap / mmdebstrap) |
| `squashfs-tools` | Compress the rootfs into a SquashFS image |
| `grub` / `grub-common` + `grub-pc-bin` + `grub-efi-amd64-bin` | Build the GRUB bootloader for the ISO |
| `xorriso` | Create hybrid ISO images (BIOS + UEFI) |
| `mtools` | Manipulate FAT filesystems (EFI image inside ISO) |
| `dosfstools` | Format FAT partitions (EFI image) |
| `binutils` / `libisoburn` | Linker and ISO manipulation tools |
| `sassc` | SCSS compiler for GRUB and Plymouth themes |
| `imagemagick` | Image processing for branding assets |
| `psmisc` | Provides `fuser` to kill leftover processes on port 5900 |
| `fakeroot` | Build packages without real root privileges |
| `rsync` | Sync the base chroot into the working target |
| `jq` / `curl` / `wget` / `unzip` / `git` | Download and extract resources during build |

### For QEMU testing (optional)

If you want to test ISOs without burning real hardware:

```bash
# Arch
sudo pacman -S qemu-full edk2-ovmf

# Debian/Ubuntu
sudo apt-get install -y qemu-system-x86 ovmf
```

## Building the ISO  
The main file for the build is `build-iso.sh`, which accepts the following flags:
- `--branch stable`, replacing stable with any other Debian branch; currently only stable can be used.
- `--local` to package from the packages in the `/PKG` folder, which must be in the same folder that contains the `/ISO` folder
- `--refind` Indicates that the rEFInd version should be built
- `--grub` Builds the GRUB version
- `--arch` Builds the ARCH version (if this flag is absent, the Debian version is built)  
- `--nvidia` Build ISO image with privative drivers (BROADCOM, NVIDIA, etc...)

## Testing in Chroot or the ISO quickly   
The file for quickly testing the ISOs is `run-qemu.sh`, which accepts the following arguments:
- `--iso` Boots from a previously built ISO image instead of directly from the chroot (build/rootfs-target)
- `--refind` Selects the rEFInd bootloader (used with `--iso`)
- `--grub` Selects the GRUB bootloader (used with `--iso`, default)
- `--nvidia` Uses the NVIDIA variant of the rootfs/ISO
- `--arch` Uses the ARCH variant of the rootfs/ISO
- `--debian` Uses the Debian variant of the rootfs/ISO (default)
- `--branch|-b <branch>` Sets the branch, must be `stable`, `forky` or `rolling` (default: `stable`)

Without `--iso`, the script boots the compiled rootfs (`build/rootfs-target-<branch>-<distro>[-nvidia]`) directly via 9pfs, without the need to package an ISO, making testing instantaneous.

## Building from GH Actions  
The ISO version, release name, and branch must be specified.  

## Packages  
PulsarOS is fully declarative; packages are built and obtained from [repo PKG](https://github.com/Inled-Pulsar-OS/PKG)
