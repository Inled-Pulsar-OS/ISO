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

The rEFInd Secure Boot builds also need the signing tool: `sbsigntools` on
Arch, `sbsigntool` on Debian/Ubuntu. The build script only requires it when the
Pulsar MOK private key is present (`ISO/assets/secureboot/pulsar-mok.key`, see
[Secure Boot & MOK](#secure-boot--mok)).

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

## Testing the ISO in QEMU

Two runners are available:

- **`run-tubeos-vm.sh`** — Tube OS VM with persistent UEFI NVRAM, virtual disk,
  user-mode NAT port forwarding and optional `virbr0` bridge. Documented in
  detail in [Running and Testing with `run-tubeos-vm.sh`](#running-and-testing-with-run-tubeos-vmsh).
- **`run-qemu.sh <iso>`** — minimal launcher for a quick smoke test: boots the
  given ISO (or the first `pulsaros-*.iso` in `build/`) with KVM + OVMF, a 25 GB
  throwaway disk at `/tmp/pulsar-test-disk.qcow2`, 4 GB RAM, 4 cores and plain
  user-mode networking. It accepts no flags.

```bash
./run-qemu.sh build/tubeos-stable-arch-refind.iso   # smoke test
./run-tubeos-vm.sh --iso --arch --refind            # full VM (ports, disk, bridge)
```

## Building from GH Actions  
The ISO version, release name, and branch must be specified.  

## Secure Boot & MOK

Both ISO bootloaders ship a Secure Boot chain. The signed binaries live in
`ISO/assets/secureboot/` (shim and MokManager come from Debian and are signed by
Microsoft; the Pulsar MOK public key is generated by `generate-mok.sh`).

**GRUB editions** (`--grub`): firmware -> Debian shim (Microsoft-signed) ->
Debian-signed GRUB. GRUB loads the kernel with the Linux boot protocol, so the
kernel does not need signing and no enrollment is required.

**rEFInd editions** (`--refind`): firmware -> `bootx64.efi` (shim) ->
`grubx64.efi` (rEFInd signed with the Pulsar MOK key). rEFInd loads the live
kernels as EFI stub images, so the build also signs `vmlinuz` and
`vmlinuz-recovery` with the same key.

The rEFInd chain requires a one-time MOK enrollment per machine, because shim
only trusts binaries signed by keys the user enrolled:

1. Write the ISO with dd / balenaEtcher (this chain is for direct USB boot;
   when booting through Ventoy, Ventoy provides its own shim/MOK handling).
2. With Secure Boot active, first boot stops at MokManager. Select
   **Enroll key from disk**, locate `EFI/BOOT/refind.cer`, confirm, and reboot.
3. rEFInd now boots. On the installed system, run
   `sudo pulsar-enroll-mok` (ships with `pulsaros-refind`) to import the MOK
   with `mokutil`; MokManager asks to confirm after the reboot.

Notes:
- Building the rEFInd secure-boot ISO requires `sbsigntool` on the build host
  (`sbsign`) and the private key `ISO/assets/secureboot/pulsar-mok.key`, which
  is gitignored on purpose. Recreate it with
  `ISO/assets/secureboot/generate-mok.sh`.
- Kernels stay in the ISO for the Ventoy/legacy paths untouched; only the
  EFI-stub copies that rEFInd loads are signed.

## Tube OS (Smart TV & Home Server Edition)

Tube OS provides a cinematic 10-foot TV user interface (Openbox + Tube OS UI / Plasma Bigscreen) and background CasaOS/Docker server capabilities.

### Building Tube OS ISO

Use `tubeos/build-tubeos.sh` (or `build-tubeos-iso.sh`):

```bash
# Full build: Arch + rEFInd bootloader + locally built packages (clean target)
sudo ./tubeos/build-tubeos.sh --arch --local --refind

# Incremental: only rebuild packages whose sources changed, keep the base cache
sudo ./tubeos/build-tubeos.sh --arch --local --refind -i

# Quick: reuse the already populated target rootfs (fastest iteration)
sudo ./tubeos/build-tubeos.sh --arch --local --refind -q

# Debian edition (Openbox + Tube OS UI + CasaOS)
sudo ./tubeos/build-tubeos.sh --debian --local
```

The ISO is written to `build/tubeos-<branch>-<distro>-<bootloader>.iso`, e.g.
`build/tubeos-stable-arch-refind.iso`.

### Running and Testing with `run-tubeos-vm.sh`

`run-tubeos-vm.sh` creates/reuses a virtual disk (`build/tubeos-disk.qcow2`),
configures UEFI (OVMF + persistent NVRAM), forwards ports and boots either the
Live ISO or the installed disk with KVM acceleration.

#### 1. Quick start (user-mode NAT, no host setup)

```bash
./run-tubeos-vm.sh --iso --arch            # auto-detects ...-grub.iso, then ...-refind.iso
./run-tubeos-vm.sh --iso --arch --refind   # force the rEFInd ISO
./run-tubeos-vm.sh --iso --debian
./run-tubeos-vm.sh --iso-path build/tubeos-stable-arch-refind.iso   # explicit path
```

The ISO name depends on the bootloader used at build time:
`tubeos-stable-<distro>-grub.iso` or `tubeos-stable-<distro>-refind.iso`.
If the file is not found, pass `--refind`/`--grub` or `--iso-path`.

Ports forwarded to the host in this mode:

| Host | Guest | Service |
| :--- | :--- | :--- |
| `http://localhost:8088` | 80 | Tube OS Web Installer / CasaOS dashboard |
| `http://localhost:8070` | 8070 | DockerMigrate |
| `localhost:2222` | 22 | SSH (`ssh -p 2222 root@localhost`, password `tubeos`) |

#### 2. Bridge mode (`virbr0`, `http://tubeos.local`)

`--passthrough` (aliases `--bridge`, `--tap`) attaches the guest NIC to the
libvirt `virbr0` bridge instead of user-mode NAT. The guest gets a real IP in
`192.168.122.0/24`, so mDNS works (`http://tubeos.local`) and the VM can be
reached from the host and from other VMs/containers on that bridge.

One-time host setup (the script tries it, but it needs root):

```bash
sudo virsh net-start default        # creates virbr0 + dnsmasq DHCP
sudo virsh net-autostart default    # keep it up after reboots
ip -br link show virbr0             # must exist before using --passthrough
```

Requirements:

- `qemu-bridge-helper` installed and setuid root
  (`/usr/lib/qemu/qemu-bridge-helper`, shipped by QEMU).
- `/etc/qemu/bridge.conf` containing `allow virbr0`.
- Your user in the `libvirt` group (and `wheel`/`sudo` for the setup step).

Then:

```bash
./run-tubeos-vm.sh --iso --arch --passthrough
sudo virsh net-dhcp-leases default     # guest IP if mDNS does not resolve
```

In bridge mode there is **no port forwarding**: the guest listens directly on
its own IP, so the installer is `http://<guest-ip>/` (port 80) and SSH is
`ssh root@<guest-ip>` (password `tubeos`).

> `virbr0` is a **NAT** bridge, not a real LAN bridge: the host reaches the VM at
> `http://tubeos.local` / `192.168.122.x`, but other machines on your LAN cannot.
> For that you need a host bridge (`br0`) bound to the physical NIC and
> `-netdev bridge,br=br0` — it depends on your network setup (NetworkManager
> bridge connection or `systemd-networkd`).

#### 3. Installed system and fresh disk

```bash
./run-tubeos-vm.sh --disk               # boot the installed system from the qcow2
./run-tubeos-vm.sh --reset-disk --iso   # wipe the disk and reinstall
./run-tubeos-vm.sh --iso --headless     # no GUI window (ports/serial only)
```

#### 4. Options reference

| Option | Description |
| :--- | :--- |
| `--iso` | Boots from the Live ISO image with the virtual disk attached (default). |
| `--disk` | Boots directly from the installed virtual disk (`tubeos-disk.qcow2`). |
| `--arch` | Selects the Arch Linux edition (default). |
| `--debian` | Selects the Debian edition. |
| `--refind` / `--grub` | Prefers `tubeos-stable-<distro>-refind.iso` / `-grub.iso`. |
| `--iso-path <path>` | Uses an explicit ISO path (skips auto-detection). |
| `--passthrough` | Bridge networking on `virbr0` (mDNS / `tubeos.local`). |
| `--reset-disk` | Re-creates an empty virtual disk before booting. |
| `--disk-size <size>` | Virtual disk size (default: `25G`). |
| `--mem <size>` | VM RAM allocation (default: `4G`; `1024M` for Debian). |
| `--smp <cores>` | VM CPU core count (default: `4`). |
| `--port <port>` | Host port for the Web UI (guest port 80, default: `8088`). |
| `--headless` | Runs without a graphical window. |

#### 5. Troubleshooting

| Symptom | Fix |
| :--- | :--- |
| `ISO file not found` | Built with `--refind`? Add `--refind` or `--iso-path build/tubeos-stable-arch-refind.iso`. |
| `Bridge virbr0 is not active` | `sudo virsh net-start default && sudo virsh net-autostart default`. |
| `failed to add tap interface` / bridge helper error | `sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper` and add `allow virbr0` to `/etc/qemu/bridge.conf`. |
| `Warning: /dev/kvm not writable` | Add your user to the `kvm` group (`sudo usermod -aG kvm $USER`, re-login). |
| `tubeos.local` does not resolve | Use the IP from `sudo virsh net-dhcp-leases default`; needs `avahi`/`nss-mdns` on the host. |

## Packages  
PulsarOS is fully declarative; packages are built and obtained from [repo PKG](https://github.com/Inled-Pulsar-OS/PKG)

## License
All the code is licensed under [MIT-INLED](https://license.inled.es)