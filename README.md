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
  fakeroot rsync jq curl unzip wget git \
  meson ninja blueprint-compiler gettext gobject-introspection gtk-update-icon-cache cmake \
  cargo rust
```

The last two lines are only needed for `--local` builds, which compile the
packages from the `/PKG` folder (custom Nautilus needs meson/ninja; the
Spotlight launcher is a Rust/GTK4 app built with cargo).

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
| `meson` / `ninja` / `blueprint-compiler` / `gettext` / `gobject-introspection` | Build the custom Nautilus (Finder) from source (`--local`) |
| `cargo` / `rust` | Build the native Spotlight launcher (Rust/GTK4, no Python) (`--local`) |

### For QEMU testing (optional)

If you want to test ISOs without burning real hardware:

```bash
# Arch
sudo pacman -S qemu-full edk2-ovmf

# Debian/Ubuntu
sudo apt-get install -y qemu-system-x86 ovmf
```

## Building the ISO  
The main file for building single ISOs is `build-iso.sh`, which accepts the following flags:
- `--branch stable`, replacing stable with any other Debian branch; currently only stable can be used.
- `--local` to package from the packages in the `/PKG` folder, which must be in the same folder that contains the `/ISO` folder
- `--refind` Indicates that the rEFInd version should be built
- `--grub` Builds the GRUB version
- `--arch` Builds the ARCH version (if this flag is absent, the Debian version is built)  
- `--nvidia` Build ISO image with privative drivers (BROADCOM, NVIDIA, etc...)
- `--minimal` Minimal lightweight build (~2-3GB target)

## Building Multiple ISOs in Parallel

To build multiple ISO editions concurrently with full isolation, thermal balancing, and zero race conditions, use `build-parallel.sh`. It automatically synchronizes concurrent tasks using `flock` and creates isolated rootfs targets to prevent directory collisions.

### Flags and Usage

| Target Flags | Description |
| --- | --- |
| `--all` | Builds all variants (Arch GRUB, Arch rEFInd, Debian GRUB, Debian rEFInd). Default if none specified. |
| `--arch-grub` | Builds the Arch Linux edition with GRUB. |
| `--arch-refind` | Builds the Arch Linux edition with rEFInd. |
| `--debian-grub` | Builds the Debian edition with GRUB. |
| `--debian-refind` | Builds the Debian edition with rEFInd. |

| Filter Flags | Description |
| --- | --- |
| `--arch` / `--arch-only` | Compiles only Arch Linux editions. |
| `--debian` / `--debian-only`| Compiles only Debian editions. |
| `--grub` / `--grub-only` | Compiles only GRUB editions. |
| `--refind` / `--refind-only` | Compiles only rEFInd editions. |

| Additional Options | Description |
| --- | --- |
| `--minimal` | Minimal lightweight build (~2-3GB target). |
| `--full` | Standard full build. |
| `--clean-base` | Deletes and rebuilds the base cache from scratch. |
| `--nvidia` | Includes proprietary NVIDIA and Broadcom drivers. |
| `--branch, -b <branch>` | Build branch (stable, forky, rolling). Default is stable. |
| `--version, -v <ver>` | Version tag for the ISOs. |
| `--skip-pkg` | Skips the local package build phase in `/PKG`. |
| `--production` | Uses remote repositories instead of local packages. |

### Examples

```bash
# Build Arch GRUB, Arch rEFInd, Debian GRUB, and Debian rEFInd simultaneously:
sudo ./build-parallel.sh --all

# Build specific combinations:
sudo ./build-parallel.sh --arch-grub --arch-refind --debian-grub

# Build all Arch versions, minimally:
sudo ./build-parallel.sh --arch --minimal

# Build all Debian versions with rEFInd:
sudo ./build-parallel.sh --debian --refind
```

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

## License
All the code is licensed under [MIT-INLED](https://license.inled.es)