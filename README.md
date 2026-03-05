# Auto-Mount USB Storage on Proxmox

[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-blue)](https://www.proxmox.com)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-lightgrey?logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![GitHub Workflow Status](https://img.shields.io/github/workflow/status/Kryxan/automount-pve/CI?label=CI)](https://github.com/Kryxan/automount-pve/actions)

Automount every partition (ext4 / NTFS / exFAT / FAT / XFS / btrfs) found on
dynamically-attached USB storage to `/mnt/<label>`. NFS & SMB sharing configured
along with recursive bind mounts to containers.

Updated for **Proxmox 9** (Debian Trixie). Should work on any systemd-based Debian 12+ system.

## Features

| Feature | Details |
|---|---|
| **Automatic mount/unmount** | udev rule triggers a systemd oneshot service on USB attach/detach |
| **Filesystem check on mount** | `ntfsfix`, `fsck.vfat`, `e2fsck`, `xfs_repair` run before every mount |
| **NTFS via ntfs-3g** | Uses the `ntfs-3g` FUSE driver instead of the kernel `ntfs` driver |
| **NFS & SMB sharing** | Interactive setup (`configure_shares.sh`) shares the entire `/mnt` tree |
| **LXC bind-mount fix** | `mnt-shared-propagation.service` addresses potential bind mount shared issue |
| **installer** | Safe to re-run; fixes broken symlinks, sets correct `chmod`/`chown` |
| **ZFS unit fix** | Removes deprecated `Requires=systemd-udev-settle` from ZFS import units (from original repo, is this still needed?) |

## Quick Start



```bash
# Download and install
curl -L https://github.com/Kryxan/automount-pve/archive/refs/heads/main.tar.gz | tar xz -C /tmp/
cd /tmp/automount-pve-main  # The extracted folder will be named automount-pve-main
./installAutoMount.sh
```


# Or clone with git
```bash
git clone https://github.com/Kryxan/automount-pve.git /opt/automount-pve
cd /opt/automount-pve
./installAutoMount.sh
```

The installer will:
1. Copy scripts to `/opt/automount-pve` and create symlinks in `/etc`.
2. Set correct ownership (`root:root`) and permissions (`0755` / `0644`).
3. Offer to install `ntfs-3g` and `exfatprogs` if missing.
4. Install `mnt-shared-propagation.service` (mount propagation fix for LXC).
5. Override ZFS units if they depend on the deprecated `systemd-udev-settle`.
6. Prompt to configure NFS and/or SMB sharing of `/mnt`.

**Test:** Plug in a USB drive and check `/mnt` for a new directory.

## LXC Container Visibility (Proxmox 9)

In Proxmox 9 I experienced an issue where USB volumes mounted under `/mnt` on
the host appear as **empty folders** inside LXC containers that bind-mount `/mnt`.

### The shared case scenareo

The problem is **mount propagation**. When an LXC container starts, it gets a
snapshot of the current mount tree. USB drives mounted *after* the container
starts are not visible unless the mount point is marked **shared**.

This project installs `mnt-shared-propagation.service` which runs:

```
mount --make-rshared /mnt
```

In troubleshooting, Ai would always confidently proclaim this was the issue. As
I saw no issue with this simple step, I've included the fix to ensure
**this is never going to be the problem!**

### The recursive bind mount exception

USB drives mounted *before* the container can also experience a seperate but similar
issue. This was my issue after upgrading to Proxmox 9. I don't think I had this 
manifest as an issue in Proxmox 8.

The typical bind mount does not propagate sub-mounts into containers (e.g. if a USB
drive mounts at /mnt/usb, it won't appear inside the container).
```
mp0: /mnt,mp=/mnt
```

Instead, force a recursive bind mount:
```
lxc.mount.entry: /mnt mnt none rbind,create=dir 0 0
```

This makes the container's `/mnt` a direct view of the host's `/mnt` tree, and
with shared propagation, USB sub-mounts appear automatically.


## File Overview

| File | Purpose |
|---|---|
| `installAutoMount.sh` | Main installer — run this |
| `mount_usb_memory.sh` | Mount/unmount handler called by the systemd service |
| `configure_shares.sh` | Interactive NFS/SMB share setup for `/mnt` |
| `add_rbind_mounts.sh` | Interactive configuration of containers for recursive bind mounts of `/mnt` |
| `99-auto-mount-sdxy.rules` | udev rule that triggers `usb-mount@.service` |
| `usb-mount@.service` | systemd template unit for mount/unmount |
| `mnt-shared-propagation.service` | Ensures `/mnt` has shared mount propagation |

## Important Notes

- **NTFS:** `ntfs-3g` is strongly recommended. Without it the kernel driver may mount
  read-only on dirty volumes. The installer offers to install it. (As I saw on Reddit,
  it's the best solution, but we're all still waiting for `ntfs-LTE`)
- **Mount labels:** The mount directory uses the partition label. If none exists, the
  device name (e.g. `sdc2`) is used. Duplicate labels get a device suffix.

