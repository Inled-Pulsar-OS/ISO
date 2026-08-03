# Pulsar OS ISO

This repository contains the ISO build script, the configuration files for preinstalled packages, and the Github Actions workflows.  
PulsarOS is built 100% by Github Actions, fully auditable end-to-end, and the ISO images are uploaded to Sourceforge (since Github Releases has very low size limits).

## Building the ISO  
The main file for the build is `build-iso.sh`, which accepts the following flags:
- `--branch stable`, replacing stable with any other Debian branch; currently only stable can be used.
- `--local` to package from the packages in the `/PKG` folder, which must be in the same folder that contains the `/ISO` folder
- `--refind` Indicates that the rEFInd version should be built
- `--grub` Builds the GRUB version
- `--arch` Builds the ARCH version (if this flag is absent, the Debian version is built)  

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
