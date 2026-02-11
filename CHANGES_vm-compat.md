# nixos-infect: Feature Detection Patch

## Problem
The original `nixos-infect` hardcodes a minimal set of kernel modules (`ata_piix`, `uhci_hcd`, `xen_blkfront`, optionally `vmw_pvscsi`) and always imports `qemu-guest.nix`. When run on a VMware hypervisor with an Ubuntu LVM root partition, this causes boot failure because:

1. The wrong/insufficient storage controller modules are included in the initrd
2. LVM is not enabled, so the volume group is never activated during boot
3. The root device path (`/dev/mapper/ubuntu--vg-ubuntu--lv`) is fragile

## Changes Overview

### New Detection Functions

| Function | Purpose |
|---|---|
| `detectVirtualization` | Identifies the hypervisor (vmware, kvm, xen, microsoft, oracle) using `systemd-detect-virt` with DMI fallback |
| `detectLVM` | Checks if root is on an LVM logical volume via device mapper paths, `lvs`, and `/sys/class/block/dm-*/dm/uuid` |
| `detectStorageModules` | Returns the correct storage kernel modules for the detected hypervisor, plus any currently loaded storage modules |
| `detectInitrdKernelModules` | Returns modules that must be force-loaded (not just available), e.g. `dm-snapshot` when LVM is detected |

### Changes to `makeConf()`

The hardcoded `availableKernelModules` array is replaced with dynamic detection:

**Before:**
```bash
availableKernelModules=('"ata_piix"' '"uhci_hcd"' '"xen_blkfront"')
if isX86_64; then
  availableKernelModules+=('"vmw_pvscsi"')
fi
```

**After:**
```bash
virt=$(detectVirtualization)
while IFS= read -r mod; do
  [[ -n "$mod" ]] && availableKernelModules+=("\"$mod\"")
done < <(detectStorageModules "$virt")
```

### Additional Improvements

1. **LVM detection** → emits `services.lvm.enable = true;` in hardware-configuration.nix
2. **UUID resolution** → resolves `/dev/mapper/...` to `/dev/disk/by-uuid/...` via `blkid` for stable boot config
3. **Guest profile selection** → picks the appropriate guest profile based on hypervisor (or skips it for VMware where no dedicated profile exists)
4. **Diagnostic logging** → prints detected virtualization, modules, and LVM status during execution

## Example Output for VMware + LVM

```nix
{ modulesPath, ... }:
{
  # VMware virtualization detected
  boot.loader.grub.device = "/dev/sda";
  boot.initrd.availableKernelModules = [ "ahci" "ata_piix" "mptspi" "sd_mod" "uhci_hcd" "vmw_pvscsi" ];
  boot.initrd.kernelModules = [ "dm-snapshot" "nvme" ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"; fsType = "ext4"; };
  services.lvm.enable = true;
}
```

## Testing Notes

- The `detectLVM` function uses multiple methods to ensure reliability across distributions
- `detectStorageModules` merges hypervisor-specific modules with currently loaded kernel modules, so it catches hardware that might not be in the static list
- All detection gracefully degrades (functions return empty/false rather than erroring) if tools like `lvs`, `systemd-detect-virt`, or `blkid` are not available
