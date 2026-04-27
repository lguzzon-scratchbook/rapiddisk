# Rapiddisk Post-Reboot Verification Failure - Root Cause Analysis Report

**Date:** 2026-04-27
**System:** Ubuntu (KVM virtual machine)
**Kernel:** 6.8.0-106-generic

---

## Summary of Findings

The rapiddisk cache on root device installation appears to complete successfully, but after reboot the kernel modules are NOT loaded and no cache is active. The investigation identified **CRITICAL BUGS** in the initramfs integration that prevent rapiddisk from activating during boot.

---

## 1. Current State Verification

### ❌ Modules Not Loading on Boot
```
$ lsmod | grep rapiddisk
(No output - modules not loaded)
```

### ❌ No RapidDisk Devices
```
$ rapiddisk -l
Unable to locate any RapidDisk devices.
```

### ❌ Root Filesystem Not Cached
```
$ mount | grep "on / "
/dev/sda2 on / type ext4 (rw,relatime,discard)
(Not on /dev/rc-* device)
```

---

## 2. Root Cause #1: CRITICAL - rapiddisk_boot Script Missing from Initramfs

### Problem Description
The `rapiddisk_boot` script, which is responsible for **executing** rapiddisk during boot, is **NOT being included in the initramfs**. This is the primary root cause.

### Evidence

**File exists on system:**
```
$ ls -la /usr/share/initramfs-tools/rapiddisk_boot
-rwxr-xr-x 1 root root 233 Apr 27 09:30 /usr/share/initramfs-tools/rapiddisk_boot
```

**But NOT in initramfs:**
```
$ lsinitramfs /boot/initrd.img-6.8.0-106-generic | grep rapiddisk_boot
(No output - rapiddisk_boot NOT in initramfs)
```

**What's actually in initramfs:**
```
scripts/local-bottom/rapiddisk_clean    ← Cleanup script (runs too late)
usr/lib/modules/*/rapiddisk.ko          ← Kernel modules (not auto-loaded)
usr/lib/modules/*/rapiddisk-cache.ko
usr/sbin/rapiddisk                       ← Binary
usr/sbin/rapiddisk_sub                   ← Script that sets up cache (NEVER EXECUTED)
```

### Technical Analysis

The initramfs hook (`rapiddisk_hook`) performs these actions:
1. ✅ Generates `rapiddisk_sub` from template
2. ✅ Copies kernel modules (rapiddisk, rapiddisk-cache)
3. ✅ Copies `rapiddisk` binary → `/sbin/rapiddisk`
4. ✅ Copies `rapiddisk_sub` → `/sbin/rapiddisk_sub`
5. ❌ **MISSING: Does NOT copy `rapiddisk_boot` to initramfs scripts directory**

The `rapiddisk_sub` script IS in the initramfs at `/sbin/rapiddisk_sub`, but it is **NEVER EXECUTED** because there's nothing calling it!

The `rapiddisk_boot` script at `/usr/share/initramfs-tools/rapiddisk_boot` contains:
```sh
if [ -x /sbin/rapiddisk_sub ] ; then
    /sbin/rapiddisk_sub
fi
```

This script needs to be in a directory like `scripts/init-premount/` to execute during boot, but the hook never copies it there.

### Why This Matters
- `rapiddisk_sub` creates the RAM disk and attaches it as cache
- Without `rapiddisk_boot` calling it, the cache is never established
- The modules are present but dormant

---

## 3. Root Cause #2: rapiddisk_sub Script Location May Be Wrong

### Problem Description
The `rapiddisk_sub` script is placed at `/sbin/rapiddisk_sub` in the initramfs, but it should be in `/scripts/init-premount/` or `/scripts/local-premount/` to be executed by the initramfs framework.

### Current Hook Behavior
```bash
# In rapiddisk_hook
copy_file binary "${cwd}/rapiddisk_sub" /sbin/
```

This places it at `/sbin/rapiddisk_sub` but there's no mechanism to execute it from there during initramfs boot phase.

### Required Fix
The `rapiddisk_sub` script should be copied to `scripts/init-premount/` or `scripts/local-premount/` directory in the initramfs, not to `/sbin/`.

---

## 4. Root Cause #3: Boot Script Execution Order

### Current Initramfs Script Order
The rapiddisk components are scattered across initramfs phases:

```
scripts/local-bottom/rapiddisk_clean    ← Runs AFTER root is mounted (too late!)
```

The `rapiddisk_clean` script runs in `local-bottom` phase which happens AFTER the root filesystem is mounted. This is wrong - rapiddisk should run in `init-premount` or `local-premount` phase, BEFORE root is mounted.

---

## 5. Secondary Issue: Module Signature Warning

### Observation
When manually loading modules:
```
[Mon Apr 27 10:27:30 2026] rapiddisk: loading out-of-tree module taints kernel.
[Mon Apr 27 10:27:30 2026] rapiddisk: module verification failed: signature and/or required key missing - tainting kernel
```

### Impact
- Modules load successfully despite the warning
- This is expected behavior for out-of-tree modules
- NOT a root cause of boot failure

---

## 6. Test: Manual Module Loading Works

When manually loaded as root, the modules work:
```
$ sudo modprobe rapiddisk
$ sudo modprobe rapiddisk-cache
$ lsmod | grep rapiddisk
rapiddisk_cache        20480  0
rapiddisk              20480  0
```

This confirms:
- ✅ Kernel modules are present and functional
- ✅ No hardware/driver incompatibility
- ✅ The issue is purely with initramfs integration

---

## 7. Installation Script Analysis

### What Works
- `make install` builds and installs modules correctly
- `update-initramfs` creates initramfs with rapiddisk files
- Config file is created: `/etc/rapiddisk/rapiddisk_kernel_6.8.0-106-generic`
- Config contains correct data:
  ```
  2048
  /dev/sda2
  wb
  ```

### What Doesn't Work
- `rapiddisk-on-boot` script installs files to wrong locations
- Hook script doesn't copy boot script to initramfs
- Initramfs doesn't execute rapiddisk during boot

---

## 8. Required Fixes

### Fix #1: Update rapiddisk_hook to Copy rapiddisk_boot

The hook script (`/usr/share/initramfs-tools/hooks/rapiddisk_hook`) must:
1. Copy `rapiddisk_boot` to `scripts/init-premount/` in the initramfs
2. Add it to the ORDER file for execution sequence

**Example fix:**
```bash
# Add to rapiddisk_hook
copy_file script "/usr/share/initramfs-tools/rapiddisk_boot" /scripts/init-premount/rapiddisk
```

### Fix #2: Update rapiddisk_sub Location

Change the hook to place `rapiddisk_sub` in the scripts directory instead of /sbin/:
```bash
# Instead of:
copy_file binary "${cwd}/rapiddisk_sub" /sbin/

# Use:
copy_file script "${cwd}/rapiddisk_sub" /scripts/init-premount/rapiddisk_sub
```

### Fix #3: Fix rapiddisk_boot to Call rapiddisk_sub

If keeping the current approach, `rapiddisk_boot` must be copied to initramfs and placed in the correct execution order.

---

## 9. Verification Steps for User

### Current State (Broken)
```bash
# Check modules
lsmod | grep rapiddisk  # No output = not loaded

# Check initramfs
lsinitramfs /boot/initrd.img-$(uname -r) | grep rapiddisk_boot  # No output = bug present
```

### Expected State (After Fix)
```bash
# After proper fix, initramfs should contain:
scripts/init-premount/rapiddisk      # or rapiddisk_boot
scripts/init-premount/rapiddisk_sub
usr/lib/modules/*/rapiddisk.ko
usr/lib/modules/*/rapiddisk-cache.ko
```

---

## 10. Workaround (Manual)

Until the bug is fixed, you can manually load rapiddisk after boot:
```bash
sudo modprobe rapiddisk
sudo modprobe rapiddisk-cache
sudo rapiddisk -a 2048                    # Create 2GB RAM disk
sudo rapiddisk -m rd0 -b /dev/sda2 -p wb  # Attach as write-back cache
```

**Note:** This will NOT cache the root filesystem as it's already mounted. This requires remounting or a reboot with proper initramfs integration.

---

## Conclusion

The rapiddisk post-reboot verification fails because of a **critical bug in the initramfs hook script** that fails to copy the `rapiddisk_boot` script into the initramfs. The script `rapiddisk_sub` (which creates the cache) is present in the initramfs but never executed because there's no boot script to call it.

**Primary Fix Required:** Update `/usr/share/initramfs-tools/hooks/rapiddisk_hook` to copy `rapiddisk_boot` to `scripts/init-premount/` in the initramfs and ensure proper execution order.

**Component:** `scripts/rapiddisk-rootdev/` (ubuntu hook installation)

**Priority:** HIGH - This prevents rapiddisk root caching from working at all.
