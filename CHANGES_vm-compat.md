# nixos-infect: VM Compatibility & Feature Detection Patch

## Problem

The original `nixos-infect` hardcodes a minimal set of kernel modules (`ata_piix`, `uhci_hcd`, `xen_blkfront`, optionally `vmw_pvscsi`) and always imports `qemu-guest.nix` regardless of the actual hypervisor. This causes boot failures or suboptimal configurations on non-KVM environments:

1. **VMware**: dead code overwrote the guest profile assignment — `vmware` was detected but then unconditionally replaced with `qemu-guest.nix`, so open-vm-tools was never enabled.
2. **Bare metal**: physical servers incorrectly imported `qemu-guest.nix` and lacked hardware RAID controller modules.
3. **NVMe**: the `nvme` module was unconditionally force-loaded in the initrd on all systems, including VMs with no NVMe hardware.
4. **LVM**: only `dm-snapshot` was included; missing `dm-mod` (core device-mapper) and `dm-mirror` (mirrored volumes) caused boot failures on some LVM setups.
5. **VirtualBox**: no guest additions were enabled, and storage modules were insufficient for paravirtualized storage.
6. **Hyper-V**: no dedicated guest profile or storage module set.
7. **Unknown hypervisors**: defaulted to `qemu-guest.nix` which could cause errors on non-QEMU platforms.

## Changes Overview

### Commits

| Commit | Description |
|--------|-------------|
| `806d402` | Initial hypervisor detection framework (`detectVirtualization`, `detectLVM`, `detectStorageModules`, `detectInitrdKernelModules`) |
| `06d6faa` | Fix guest profiles, storage modules, LVM dm-mod/dm-mirror, conditional NVMe |
| `42ee17b` | Fix syntax corruption from line-level edits |
| `a7fe120` | Expand lsmod storage pattern with RAID modules, fix docstring, deduplicate doNetConf |

### New Detection Functions

| Function | Purpose |
|---|---|
| `detectVirtualization` | Identifies the hypervisor using `systemd-detect-virt` with DMI `sys_vendor` fallback. Returns: `vmware`, `kvm`, `qemu`, `microsoft`, `oracle`, `xen`, `none` (bare metal), container types (`lxc`, `docker`, `openvz`, `systemd-nspawn`, `podman`, `wsl`), or `unknown`. |
| `detectLVM` | Checks if root is on an LVM logical volume via `/dev/mapper/` paths, `lvs` verification, and `/sys/class/block/dm-*/dm/uuid` prefix matching. Distinguishes LVM from plain dm or LUKS. |
| `detectStorageModules` | Returns the correct storage kernel modules for the detected hypervisor, merges with currently loaded kernel modules from `lsmod`, and adds NVMe if `/sys/class/nvme` exists. |
| `detectInitrdKernelModules` | Returns modules that must be force-loaded in initrd (not just available). Currently emits `dm-mod`, `dm-snapshot`, `dm-mirror` when LVM is detected. |

### Guest Profile Selection

The hardcoded `qemu-guest.nix` import is replaced with hypervisor-specific profiles:

| Detected virt | Guest profile / module |
|---|---|
| `vmware` | `virtualisation.vmware.guest.enable = true` (enables open-vm-tools) |
| `kvm` / `qemu` | `imports = [ qemu-guest.nix ]` (unchanged from original for KVM) |
| `microsoft` | `imports = [ hyperv-guest.nix ]` |
| `oracle` | `virtualisation.virtualbox.guest.enable = true` (enables guest additions) |
| `xen` | `imports = [ qemu-guest.nix ]` |
| `none` (bare metal) | No guest profile — comment only |
| Container types | Warning logged, no guest profile |
| Unknown | Warning logged, no guest profile (previously defaulted to qemu-guest) |

### Storage Module Selection

| Detected virt | Static modules |
|---|---|
| `vmware` | `vmw_pvscsi`, `mptspi`, `ahci`, `sd_mod` |
| `kvm` / `qemu` | `virtio_pci`, `virtio_blk`, `virtio_scsi`, `ahci`, `sd_mod` |
| `microsoft` | `hv_storvsc`, `hv_vmbus`, `sd_mod` |
| `oracle` | `ahci`, `sd_mod`, `virtio_pci`, `virtio_blk`, `virtio_scsi` |
| `xen` | `xen_blkfront` |
| `none` (bare metal) | `ahci`, `sd_mod`, `nvme`, `megaraid_sas`, `mpt3sas`, `aacraid`, `hpsa`, `virtio_pci`, `virtio_blk`, `virtio_scsi` |
| Unknown / fallback | `ahci`, `sd_mod`, `virtio_pci`, `virtio_blk`, `virtio_scsi`, `hv_storvsc`, `xen_blkfront`, `nvme` |

All cases also include `ata_piix` and `uhci_hcd`. The dynamic `lsmod` scan adds any loaded modules matching the storage pattern. NVMe is added to `availableKernelModules` if `/sys/class/nvme` exists and only force-loaded in `initrd.kernelModules` if NVMe hardware is present.

### Additional Improvements

1. **LVM detection** → emits `services.lvm.enable = true` and force-loads `dm-mod`, `dm-snapshot`, `dm-mirror` in initrd
2. **UUID resolution** → resolves root device to `/dev/disk/by-uuid/...` via `blkid` for stable boot config
3. **Conditional NVMe** → only force-loads `nvme` in initrd when `/sys/class/nvme` exists
4. **Diagnostic logging** → prints detected virtualization, module lists, LVM status, and UUID resolution during execution
5. **Deduplicated doNetConf** → removed redundant standalone DigitalOcean `doNetConf=y` assignment

## Example Outputs

### VMware + LVM (BIOS boot)

```nix
{ modulesPath, ... }:
{
  virtualisation.vmware.guest.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.initrd.availableKernelModules = [ "ahci" "ata_piix" "mptspi" "sd_mod" "uhci_hcd" "vmw_pvscsi" ];
  boot.initrd.kernelModules = [ "dm-mirror" "dm-mod" "dm-snapshot" ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"; fsType = "ext4"; };
  services.lvm.enable = true;
}
```

### KVM + NVMe (EFI boot, no LVM)

```nix
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = { device = "/dev/disk/by-uuid/AAAA-BBBB"; fsType = "vfat"; };
  boot.initrd.availableKernelModules = [ "ahci" "ata_piix" "nvme" "sd_mod" "uhci_hcd" "virtio_blk" "virtio_pci" "virtio_scsi" ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"; fsType = "ext4"; };
}
```

### Bare Metal (no LVM, no NVMe)

```nix
{ modulesPath, ... }:
{
  # Physical hardware detected — no guest profile
  boot.loader.grub.device = "/dev/sda";
  boot.initrd.availableKernelModules = [ "aacraid" "ahci" "ata_piix" "hpsa" "megaraid_sas" "mpt3sas" "nvme" "sd_mod" "uhci_hcd" "virtio_blk" "virtio_pci" "virtio_scsi" ];
  boot.initrd.kernelModules = [ ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"; fsType = "ext4"; };
}
```

---

## Testing Matrix

Each row is an environment that exercises a distinct code path. "Pass" means the system boots successfully into NixOS with working storage and appropriate guest tooling.

### Core Hypervisor × Storage Tests

These are the primary test cases — each hypervisor type combined with the storage configurations most likely to be encountered on that platform.

| # | Hypervisor | Storage | Boot | Root FS | Verify | Pass |
|---|---|---|---|---|---|---|
| 1 | **KVM/QEMU** (virtio disk) | `/dev/vda1` | BIOS | ext4 | `qemu-guest.nix` imported, `virtio_*` in modules, no NVMe in initrd | |
| 2 | **KVM/QEMU** (virtio disk) | `/dev/vda1` | EFI | ext4 | Same as #1 but EFI grub config, ESP mounted | |
| 3 | **KVM/QEMU** (NVMe) | `/dev/nvme0n1p1` | EFI | ext4 | `nvme` in both available and initrd kernelModules | |
| 4 | **KVM/QEMU** + LVM | `/dev/mapper/vg-root` | BIOS | ext4 | `dm-mod`/`dm-snapshot`/`dm-mirror` in initrd, `services.lvm.enable`, UUID resolved | |
| 5 | **VMware ESXi** (PVSCSI) | `/dev/sda1` | BIOS | ext4 | `vmware.guest.enable = true`, `vmw_pvscsi` + `mptspi` in modules, no `qemu-guest.nix` | |
| 6 | **VMware ESXi** + LVM | `/dev/mapper/vg-root` | BIOS | ext4 | Same as #5 plus LVM config and dm-* modules | |
| 7 | **VMware ESXi** (PVSCSI) | `/dev/sda1` | EFI | ext4 | Same as #5 but EFI boot | |
| 8 | **Hyper-V** | `/dev/sda1` | BIOS | ext4 | `hyperv-guest.nix` imported, `hv_storvsc` + `hv_vmbus` in modules | |
| 9 | **Hyper-V** | `/dev/sda1` | EFI | ext4 | Same as #8 but EFI boot | |
| 10 | **VirtualBox** (AHCI) | `/dev/sda1` | BIOS | ext4 | `virtualbox.guest.enable = true`, `ahci` + `sd_mod` in modules | |
| 11 | **VirtualBox** (paravirt) | `/dev/sda1` | EFI | ext4 | Same as #10, plus `virtio_*` in modules | |
| 12 | **Xen** (PV) | `/dev/xvda1` | BIOS | ext4 | `qemu-guest.nix` imported, `xen_blkfront` in modules | |
| 13 | **Bare metal** (SATA/AHCI) | `/dev/sda1` | BIOS | ext4 | No guest profile, broad module set including RAID drivers | |
| 14 | **Bare metal** (NVMe) | `/dev/nvme0n1p1` | EFI | ext4 | No guest profile, `nvme` in both available and initrd | |
| 15 | **Bare metal** + LVM | `/dev/mapper/vg-root` | BIOS | ext4 | No guest profile, LVM + dm-* modules, RAID drivers available | |
| 16 | **Bare metal** (HW RAID) | `/dev/sda1` | EFI | ext4 | Verify `megaraid_sas`/`mpt3sas`/`aacraid`/`hpsa` picked up from lsmod | |

### Cloud Provider Tests

These test real-world deployment targets where nixos-infect is most commonly used.

| # | Provider | Instance type | Expected virt | Expected storage | Verify | Pass |
|---|---|---|---|---|---|---|
| 17 | **Hetzner Cloud** | CX-series (x86) | `kvm` | virtio + BIOS | `doNetConf=y`, virtio modules, qemu-guest profile | |
| 18 | **Hetzner Cloud** | CAX (ARM64) | `kvm` | virtio + EFI | Same as #17 but ARM64 + EFI | |
| 19 | **DigitalOcean** | Standard droplet | `kvm` | virtio + BIOS | `doNetConf=y`, networking.nix generated | |
| 20 | **AWS Lightsail** | Standard | `kvm` / `xen` | NVMe | Uses `makeLightsailConf` path (separate codepath) | |
| 21 | **Oracle Cloud** | Free tier (KVM) | `kvm` | paravirt | virtio modules, qemu-guest profile | |
| 22 | **Vultr** | Standard | `kvm` | virtio | virtio modules, qemu-guest profile | |
| 23 | **Azure** | Standard VM | `microsoft` | Hyper-V | hyperv-guest profile, `hv_storvsc` modules | |
| 24 | **GCP** | e2-micro | `kvm` | virtio-scsi | virtio modules, qemu-guest profile | |

### Edge Cases & Fallback Behavior

These test graceful degradation and unusual configurations.

| # | Scenario | Expected behavior | Pass |
|---|---|---|---|
| 25 | **No `systemd-detect-virt`** available | Falls back to DMI `sys_vendor` check | |
| 26 | **No DMI** (no `/sys/class/dmi/id/sys_vendor`) | Returns `unknown`, uses broad fallback module set | |
| 27 | **Container: LXC** | Warning logged, no guest profile, no crash | |
| 28 | **Container: Docker** | Warning logged, no guest profile, no crash | |
| 29 | **Container: WSL** | Warning logged, no guest profile, no crash | |
| 30 | **Unknown hypervisor** (novel platform) | Warning logged, broad fallback modules, no guest profile | |
| 31 | **LUKS on root** (dm but not LVM) | `detectLVM` returns false — no LVM config, no dm-* modules forced | |
| 32 | **LVM without `lvs` installed** | Falls back to dm UUID check (`LVM-` prefix in sysfs) | |
| 33 | **No `blkid` available** | UUID resolution skipped, raw device path used | |
| 34 | **Existing config** (`/etc/nixos/configuration.nix` present) | `makeConf` returns early (no overwrite) | |
| 35 | **Multiple dm devices** (LVM root + LUKS data) | `detectLVM` returns true (Method 2 scans all dm uuids) | |
| 36 | **NVMe absent, KVM with virtio** | No `nvme` in initrd kernelModules, only in available if lsmod shows it | |
| 37 | **Existing swap partition** (`swapon` active on `/dev/...`) | `zramswap=false`, swap device configured, `NO_SWAP` set | |
| 38 | **PROVIDER=servarica** | `doNetConf=y`, networking.nix generated | |

### Verification Checklist per Test

For each test case, verify:

- [ ] `hardware-configuration.nix` contains the correct guest profile (or no profile)
- [ ] `boot.initrd.availableKernelModules` contains the expected storage modules
- [ ] `boot.initrd.kernelModules` contains `dm-*` only when LVM is present, `nvme` only when NVMe hardware is present
- [ ] `fileSystems."/"` uses UUID path when `blkid` succeeds
- [ ] `services.lvm.enable = true` is present only when LVM is detected
- [ ] Boot loader config matches BIOS vs EFI
- [ ] System boots successfully and the root filesystem is mounted
- [ ] Guest tools are running where applicable (open-vm-tools, VBox guest additions, Hyper-V daemons)
- [ ] Diagnostic log output shows correct detection values

### Minimal Smoke Test Set

If full matrix testing is not feasible, prioritize these 8 tests which cover every major code path:

| Priority | Test # | Covers |
|---|---|---|
| P0 | #1 | KVM + virtio (most common cloud case) |
| P0 | #5 | VMware (guest profile fix — was broken before) |
| P0 | #4 | KVM + LVM (dm-mod fix) |
| P0 | #13 | Bare metal (no-guest-profile fix — was broken before) |
| P1 | #8 | Hyper-V (new guest profile) |
| P1 | #10 | VirtualBox (new guest profile) |
| P1 | #14 | Bare metal + NVMe (conditional NVMe) |
| P2 | #26 | Unknown fallback (regression safety net) |
