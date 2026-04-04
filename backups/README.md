# Backups Guide — Proxmox VE 9.1

This guide covers two backup strategies for a Proxmox homelab:

- **Option A**: Proxmox Backup Server (PBS) — recommended, supports deduplication and incremental backups
- **Option B**: local backup to a directory or NFS share — simpler, no extra server needed

---

## Table of Contents

1. [Backup Concepts in Proxmox](#1-backup-concepts-in-proxmox)
2. [Option A: Proxmox Backup Server (PBS)](#2-option-a-proxmox-backup-server-pbs)
3. [Option B: Local Directory or NFS Backup](#3-option-b-local-directory-or-nfs-backup)
4. [Backup Jobs: Schedule and Retention](#4-backup-jobs-schedule-and-retention)
5. [Restore a VM or LXC](#5-restore-a-vm-or-lxc)
6. [Verify Your Backups](#6-verify-your-backups)
7. [Backup Script](#7-backup-script)

---

## 1. Backup Concepts in Proxmox

### Backup modes

| Mode      | VM state during backup | Requires QEMU agent | Notes                              |
|-----------|------------------------|---------------------|------------------------------------|
| Snapshot  | Running                | Yes                 | Minimal downtime, best option      |
| Suspend   | Briefly suspended      | No                  | Short freeze, then continues       |
| Stop      | Shut down              | No                  | Safest consistency, longest window |

Use **Snapshot** mode for production VMs with the QEMU agent installed.
Use **Stop** mode for VMs without the agent, or when data consistency is critical.

### Backup formats

- **VMA** (`.vma.zst`): native Proxmox format. Stores disk + config. Used by vzdump and PBS.
- **tar.zst**: used for LXC containers.

### Retention policy

Proxmox supports keeping the last N backups, or defining a pruning schedule (keep-daily, keep-weekly, keep-monthly, keep-yearly). PBS handles this natively.

---

## 2. Option A: Proxmox Backup Server (PBS)

PBS is a separate product from Proxmox. Install it on a second machine or a dedicated VM on a different physical host.

Download: [https://www.proxmox.com/en/downloads](https://www.proxmox.com/en/downloads)

PBS ISO: **Proxmox Backup Server 3.x** — verifier la derniere version disponible sur [proxmox.com/en/downloads](https://www.proxmox.com/en/downloads).

### Install PBS

Boot from the PBS ISO. Installation is similar to Proxmox VE:
- Assign a static IP (e.g. `192.168.1.20/24`)
- Set a strong root password
- Select a disk (PBS writes backups here — size it accordingly)

Access the PBS web UI at `https://192.168.1.20:8007`.

### Create a datastore

In the PBS web UI: **Administration** > **Datastores** > **Create Datastore**

| Field    | Value                  |
|---------|------------------------|
| Name     | backup-store           |
| Backing Path | /mnt/backup (or your disk mount point) |

### Create a backup user in PBS

```bash
# On the PBS host
proxmox-backup-manager user create backup-user@pbs --password 'StrongPass1!'
proxmox-backup-manager acl update /datastore/backup-store backup-user@pbs DatastoreBackup
```

### Get the PBS fingerprint

```bash
# On the PBS host
proxmox-backup-manager cert info | grep Fingerprint
```

### Add PBS as storage in Proxmox

**Datacenter** > **Storage** > **Add** > **Proxmox Backup Server**

| Field        | Value                               |
|-------------|-------------------------------------|
| ID          | pbs-01                              |
| Server      | 192.168.1.20                        |
| Username    | backup-user@pbs                     |
| Password    | StrongPass1!                        |
| Datastore   | backup-store                        |
| Fingerprint | (paste from PBS)                    |
| Encryption key | Optional — generate in PBS UI   |

### Enable client-side encryption (optional but recommended)

In the storage config, click **Encryption** > **Generate** to create an encryption key.
Store this key somewhere safe (not only on the Proxmox host).

Backups stored in PBS will be encrypted at rest. The key is required for any restore.

---

## 3. Option B: Local Directory or NFS Backup

### Local directory

**Datacenter** > **Storage** > **Add** > **Directory**

| Field    | Value                  |
|---------|------------------------|
| ID       | backup-local           |
| Directory | /mnt/backup-disk      |
| Content  | VZDump backup file     |

Mount an external disk:

```bash
# Find the disk
lsblk
# Format if needed (only on first use)
mkfs.ext4 /dev/sdb1
# Mount
mkdir -p /mnt/backup-disk
echo '/dev/sdb1 /mnt/backup-disk ext4 defaults,nofail 0 2' >> /etc/fstab
mount -a
```

### NFS share

Mount an NFS share from a NAS:

```bash
apt install -y nfs-common
mkdir -p /mnt/nas-backup

# Add to /etc/fstab
echo '192.168.1.30:/volume1/proxmox-backup /mnt/nas-backup nfs defaults,nofail 0 0' >> /etc/fstab
mount -a
```

Then add as a Directory storage in Proxmox.

---

## 4. Backup Jobs: Schedule and Retention

### Create a backup job

**Datacenter** > **Backup** > **Add**

| Field        | Recommended value              |
|-------------|-------------------------------|
| Storage      | pbs-01 (or backup-local)      |
| Schedule     | 03:00 (daily at 3 AM)         |
| Selection    | All (or select specific VMs)  |
| Mode         | Snapshot                      |
| Compression  | ZSTD                          |
| Send email   | your@email.com (for failures) |

> **Note:** Proxmox VE does not include a mail transfer agent (MTA) by default. To use `--notify-email`, install one first: `apt-get install postfix` (or `msmtp` for a lightweight alternative).

### PBS retention (prune schedule)

In PBS: **Datastore** > **backup-store** > **Prune & GC** > **Add Prune Job**

```
keep-last:    3
keep-daily:   7
keep-weekly:  4
keep-monthly: 3
```

This keeps:
- 3 most recent backups regardless of age
- 1 backup per day for the last 7 days
- 1 backup per week for the last 4 weeks
- 1 backup per month for the last 3 months

For local/directory storage, set retention in the backup job:
**Max Backups**: 7 (keep last 7).

---

## 5. Restore a VM or LXC

### Restore via the web UI

1. Navigate to **local** (or **pbs-01**) storage > **Backups**.
2. Select the backup file.
3. Click **Restore**.
4. Assign a new VM ID and storage, then click **Restore**.

### Restore via CLI

```bash
# List available backups
pvesm list pbs-01

# Restore a VM (adjust backup path and target storage)
qmrestore pbs-01:backup/vm/101/2026-04-01T03:00:00Z 101 \
  --storage local-lvm \
  --unique 1

# Restore an LXC
pct restore 200 pbs-01:backup/ct/200/2026-04-01T03:00:00Z \
  --storage local-lvm \
  --unique 1
```

`--unique 1`: assigns a new unique MAC address and VMID to avoid conflicts.

### Test restore to a different VM ID

Always test restores before relying on them in a real incident:

```bash
qmrestore pbs-01:backup/vm/101/2026-04-01T03:00:00Z 999 \
  --storage local-lvm
qm start 999
# Verify the VM boots and data is intact
qm destroy 999
```

---

## 6. Verify Your Backups

See [backup-job.sh](backup-job.sh) for an automated verification script.

### Check backup age via PBS API

```bash
# On the PBS host or via API
proxmox-backup-client list --repository backup-user@pbs@192.168.1.20:backup-store
```

### Check backup age on local storage

```bash
# List backup files with timestamps
ls -lht /mnt/backup-disk/dump/ | head -20
```

### Verify PBS backup integrity

PBS stores SHA-256 checksums for every chunk. Run a verification job:

**PBS web UI** > **Datastore** > **backup-store** > **Verify** > **Verify All**

Or via CLI on the PBS host:

```bash
proxmox-backup-manager verify backup-store
```

---

## 7. Backup Script

The script [backup-job.sh](backup-job.sh) checks the age of the latest backup for each VM and sends an alert if:

- No backup exists in the last 24 hours
- The backup job returned an error

Usage:

```bash
bash backups/backup-job.sh --storage pbs-01 --max-age-hours 26
```

Configure it as a cron job on the Proxmox host:

```bash
# Edit crontab
crontab -e

# Run every day at 05:30 (after the 03:00 backup job)
30 5 * * * /root/homelab-proxmox-starter/backups/backup-job.sh \
  --storage pbs-01 --max-age-hours 26 >> /var/log/backup-check.log 2>&1
```
