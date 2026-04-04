# homelab-proxmox-starter

A complete step-by-step guide to building a homelab on Proxmox VE 9.1.
No complex stack, no Kubernetes, no over-engineering. Just a solid foundation.

---

## Table of Contents

1. [Hardware Requirements](#1-hardware-requirements)
2. [Install Proxmox VE 9.1](#2-install-proxmox-ve-91)
3. [Post-Install Configuration](#3-post-install-configuration)
4. [Network Configuration](#4-network-configuration)
5. [Create Your First VM](#5-create-your-first-vm)
6. [Create a VM Template for Fast Cloning](#6-create-a-vm-template-for-fast-cloning)
7. [LXC Containers](#7-lxc-containers)
8. [Backups with Proxmox Backup Server](#8-backups-with-proxmox-backup-server)
9. [Monitoring with Prometheus and Grafana](#9-monitoring-with-prometheus-and-grafana)
10. [Basic Hardening](#10-basic-hardening)
11. [Useful Daily Commands](#11-useful-daily-commands)
12. [Directory Structure of This Repo](#12-directory-structure-of-this-repo)

---

## 1. Hardware Requirements

Proxmox VE is a Type-1 hypervisor. It runs directly on bare metal. Do not install it inside a VM.

### Minimum viable homelab

| Component    | Minimum              | Recommended              |
|-------------|----------------------|--------------------------|
| CPU          | 4 cores, VT-x/VT-d   | 8+ cores, VT-x/VT-d/IOMMU |
| RAM          | 16 GB                | 32–64 GB ECC             |
| System disk  | 32 GB SSD            | 120 GB SSD (dedicated)   |
| VM storage   | 256 GB HDD/SSD       | 1 TB+ NVMe or ZFS pool   |
| NIC          | 1x 1GbE              | 2x 1GbE or 1x 10GbE      |

### CPU flags to verify

Before buying or repurposing hardware, confirm your CPU supports:

- `vmx` (Intel VT-x) or `svm` (AMD-V) — required for VMs
- `ept` or `npt` — required for nested virtualisation
- `vt-d` (Intel) or `amd-iommu` (AMD) — required for PCIe passthrough (GPU, NIC, HBA)

Check on a running Linux system:

```bash
grep -E 'vmx|svm' /proc/cpuinfo | head -1
```

### Storage recommendations

- **System/boot**: a dedicated SSD, even 32 GB is fine. Keep VM storage separate.
- **VM storage**: ZFS on NVMe gives you snapshots, checksums, and compression for free.
- **Avoid USB boot**: Proxmox writes heavily to the system disk (logs, corosync). USB drives wear out fast.

---

## 2. Install Proxmox VE 9.1

### Download the ISO

Download the official ISO from [https://www.proxmox.com/en/downloads](https://www.proxmox.com/en/downloads).

Current version as of April 2026: **Proxmox VE 9.1**.

Verify the checksum before flashing:

```bash
sha256sum proxmox-ve_9.1-1.iso
```

Compare against the published SHA256 on the download page.

### Flash to USB

```bash
# Linux / macOS
dd if=proxmox-ve_9.1-1.iso of=/dev/sdX bs=4M status=progress oflag=sync

# Windows: use Rufus (write in DD mode, not ISO mode)
```

### Boot and install

1. Boot from USB. Select **Install Proxmox VE (Graphical)**.
2. Accept the EULA.
3. **Target disk**: select your dedicated system SSD. Check **Options** if you want ZFS on the system disk (recommended if you have 2+ disks for a mirror).
4. **Location and time zone**: set your country and timezone.
5. **Password and email**: set a strong root password. The email is used for alerts.
6. **Network configuration**:
   - Management interface: pick your primary NIC.
   - Hostname: use a FQDN, e.g. `pve01.lab.local`.
   - IP: assign a static IP on your LAN, e.g. `192.168.1.10/24`.
   - Gateway: your router IP, e.g. `192.168.1.1`.
   - DNS: `192.168.1.1` or `1.1.1.1`.
7. Review the summary and click **Install**.
8. Remove USB, reboot.

Access the web UI at `https://192.168.1.10:8006`. Accept the self-signed certificate warning.

---

## 3. Post-Install Configuration

### Disable the enterprise repository (requires paid subscription)

The enterprise repo is enabled by default but requires a Proxmox subscription. Comment it out:

```bash
# On the Proxmox host via SSH or the web shell
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
```

Same for the Ceph enterprise repo if it exists:

```bash
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
  sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list
fi
```

### Enable the no-subscription repository

```bash
cat >> /etc/apt/sources.list << 'EOF'

# Proxmox VE No-Subscription Repo
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
```

### Remove the subscription nag popup

The web UI shows a nag dialog on login if no subscription is active. Remove it:

```bash
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

# Restart the web service to apply
systemctl restart pveproxy
```

Note: this patch needs to be reapplied after each Proxmox update.

### Update the system

```bash
apt update && apt dist-upgrade -y
```

After updating, reboot if the kernel changed:

```bash
reboot
```

### Set the correct time zone

```bash
timedatectl set-timezone Europe/Brussels
timedatectl status
```

---

## 4. Network Configuration

See [network/README.md](network/README.md) for the full guide.

### Default bridge: vmbr0

Proxmox creates a Linux bridge `vmbr0` during installation. It maps to your physical NIC and is what VMs use for network access.

Check the current config:

```bash
cat /etc/network/interfaces
```

Typical output:

```
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

### Add a second bridge for isolated VM traffic

```bash
# Append to /etc/network/interfaces
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Internal only — no physical NIC attached
```

Apply:

```bash
ifreload -a
```

### VLAN configuration

For VLAN tagging across a managed switch, see [network/vlan-setup.sh](network/vlan-setup.sh).
Quick summary: you create a VLAN-aware bridge and tag VMs at the VM config level, not at the bridge level.

---

## 5. Create Your First VM

### Download an ISO

In the Proxmox web UI:

1. Navigate to your node > **local** storage > **ISO Images**.
2. Click **Download from URL**.
3. URL: `https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso`
4. Click **Query URL**, verify the filename, then **Download**.

Or via CLI:

```bash
wget -P /var/lib/vz/template/iso/ \
  https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso
```

### Create the VM via CLI (qm)

```bash
qm create 100 \
  --name ubuntu-2404 \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:32 \
  --ide2 local:iso/ubuntu-24.04.4-live-server-amd64.iso,media=cdrom \
  --boot order=ide2 \
  --agent enabled=1
```

Start it:

```bash
qm start 100
```

Open the console in the web UI to complete the Ubuntu installation.

### Recommended VM settings

- **CPU type**: `host` — passes through the real CPU model. Gives better performance and enables all CPU features. Do not use `kvm64` unless migrating between heterogeneous hosts.
- **Disk**: `virtio-scsi` controller. Better performance than IDE or SATA.
- **Network**: `virtio` model. Always. It is the fastest para-virtual NIC.
- **QEMU Guest Agent**: install it inside the VM so Proxmox can report the IP and do clean shutdowns.

Inside Ubuntu after install:

```bash
apt install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

---

## 6. Create a VM Template for Fast Cloning

Templates let you spin up a new VM in seconds instead of installing from scratch every time.

### Prepare the base VM

Start from the VM you created in step 5 (ID 100). Do a minimal install, run updates, install the guest agent, then clean up:

```bash
# Inside the VM
apt update && apt upgrade -y
apt install -y qemu-guest-agent cloud-init
systemctl enable qemu-guest-agent

# Remove SSH host keys (they will be regenerated on first boot)
rm /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id

# Clean up
apt clean
cloud-init clean
```

Shut down the VM:

```bash
qm shutdown 100
```

### Add a cloud-init drive and convert to template

```bash
# Add cloud-init drive
qm set 100 --ide1 local-lvm:cloudinit

# Set cloud-init defaults
qm set 100 \
  --ciuser thomas \
  --sshkeys ~/.ssh/authorized_keys \
  --ipconfig0 ip=dhcp

# Convert to template
qm template 100
```

See [vms/cloud-init.yaml](vms/cloud-init.yaml) for a full cloud-init configuration example.

### Clone the template

```bash
# Full clone (independent disk)
qm clone 100 201 --name webserver-01 --full

# Start the clone
qm start 201
```

A full clone takes about 10–30 seconds depending on disk speed.

---

## 7. LXC Containers

LXC containers share the host kernel. They are lighter than VMs and start in under a second. Use them for services that do not need a full OS (Nginx, Pi-hole, Home Assistant, etc.).

### Download a container template

```bash
pveam update
pveam available | grep ubuntu
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

### Create an LXC container

```bash
pct create 200 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname pihole \
  --memory 512 \
  --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --storage local-lvm \
  --rootfs local-lvm:8 \
  --password changeme \
  --unprivileged 1 \
  --start 1
```

Access the console:

```bash
pct enter 200
```

### Privileged vs unprivileged

- **Unprivileged** (recommended): UIDs are remapped. Root inside the container is not root on the host. Use this by default.
- **Privileged**: required for some use cases (NFS mounts, Docker inside LXC, some kernel modules). Only use when needed.

---

## 8. Backups with Proxmox Backup Server

See [backups/README.md](backups/README.md) for the full guide.

### Option A: Proxmox Backup Server (PBS) — recommended

PBS is a dedicated backup solution from Proxmox. It supports deduplication, incremental backups, and encryption. Run it on a second machine or a dedicated VM on another host.

Install PBS from [https://www.proxmox.com/en/downloads](https://www.proxmox.com/en/downloads) on a separate machine.

### Add PBS as a storage backend in Proxmox

In the web UI: **Datacenter** > **Storage** > **Add** > **Proxmox Backup Server**.

| Field         | Value                              |
|--------------|------------------------------------|
| ID           | pbs-01                             |
| Server       | 192.168.1.20 (your PBS IP)         |
| Datastore    | backup-store (your PBS datastore)  |
| Username     | backup-user@pbs                    |
| Password     | (your PBS backup user password)    |
| Fingerprint  | (shown in PBS dashboard)           |

### Option B: local backup to a directory

For a simple setup without PBS, back up to a local directory or NFS share:

**Datacenter** > **Storage** > **Add** > **Directory**

Then create a backup job: **Datacenter** > **Backup** > **Add**

```
Storage:    local (or your NFS share)
Schedule:   03:00 (daily at 3 AM)
Mode:       Snapshot (requires QEMU agent) or Suspend
Compress:   zstd
Max Backups: 3
```

### Verify backups

See [backups/backup-job.sh](backups/backup-job.sh) for a script that checks backup age and sends an alert if a backup is stale.

---

## 9. Monitoring with Prometheus and Grafana

See [monitoring/README.md](monitoring/README.md) for the full guide.

### Architecture

```
Proxmox host
  └── pve-exporter (scrapes Proxmox API)
  └── node_exporter (host metrics)

Monitoring VM
  └── Prometheus (scrapes exporters)
  └── Grafana (dashboards)
```

### Deploy a monitoring VM or LXC

Create a small Ubuntu 24.04 LXC (512 MB RAM, 2 cores, 10 GB disk) or VM.

### Install Prometheus

```bash
apt install -y prometheus
```

Replace the default config with [monitoring/prometheus.yml](monitoring/prometheus.yml).

```bash
cp prometheus.yml /etc/prometheus/prometheus.yml
systemctl restart prometheus
```

### Install Grafana

```bash
apt install -y apt-transport-https software-properties-common
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt update && apt install -y grafana
systemctl enable --now grafana-server
```

Access Grafana at `http://monitoring-vm-ip:3000`. Default credentials: `admin / admin`.

Import the Proxmox dashboard: ID **10347** (Proxmox via Prometheus) from grafana.com.

---

## 10. Basic Hardening

See [security/README.md](security/README.md) for the full hardening guide.

### Quick wins

**Disable root SSH login:**

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
```

**Enable the Proxmox firewall (datacenter level):**

In the web UI: **Datacenter** > **Firewall** > **Options** > set **Firewall** to `Yes`.

Then set the default policy to DROP and add explicit ACCEPT rules for:
- Port 8006 (web UI) from your management VLAN
- Port 22 (SSH) from your management VLAN
- Port 3128 (SPICE proxy) if you use SPICE consoles

**Enable 2FA:**

**Datacenter** > **Permissions** > **Two Factor** > **Add** > **TOTP**

Scan the QR code with an authenticator app (Aegis, Bitwarden, etc.).

**Create a non-root user for daily use:**

```bash
pveum user add thomas@pve --password 'strongpassword'
pveum role add HomeLabAdmin --privs \
  "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Disk \
   VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
   VM.Console VM.Monitor VM.PowerMgmt VM.Snapshot Datastore.AllocateSpace \
   Datastore.Audit Pool.Allocate Sys.Audit Sys.Console"
pveum aclmod / -user thomas@pve -role HomeLabAdmin
```

---

## 11. Useful Daily Commands

### VM management

```bash
# List all VMs
qm list

# Start / stop / reset
qm start <vmid>
qm shutdown <vmid>
qm reset <vmid>

# Show VM config
qm config <vmid>

# Create a snapshot
qm snapshot <vmid> snap-before-update --description "Before dist-upgrade"

# Rollback to snapshot
qm rollback <vmid> snap-before-update

# Delete snapshot
qm delsnapshot <vmid> snap-before-update
```

### LXC management

```bash
# List containers
pct list

# Start / stop / enter
pct start <ctid>
pct stop <ctid>
pct enter <ctid>

# Show config
pct config <ctid>
```

### Storage and ZFS

```bash
# List storage
pvesm status

# ZFS pool status
zpool status

# ZFS filesystem list
zfs list

# Show disk usage per dataset
zfs list -o name,used,avail,refer
```

### Cluster and node

```bash
# Node status
pvesh get /nodes/$(hostname)/status

# Task log
pvesh get /nodes/$(hostname)/tasks --limit 20

# Check service status
systemctl status pve-cluster pveproxy pvedaemon
```

### Logs

```bash
# Proxmox cluster log
journalctl -u pve-cluster -f

# Task log for a specific VM
cat /var/log/pve/tasks/active
```

---

## 12. Directory Structure of This Repo

```
homelab-proxmox-starter/
├── README.md               # This file — full step-by-step tutorial
├── network/
│   ├── README.md           # Network guide: bridges, VLANs, pfSense
│   └── vlan-setup.sh       # VLAN configuration script for Proxmox
├── vms/
│   ├── README.md           # VM creation and template guide
│   └── cloud-init.yaml     # Cloud-init example for Ubuntu 24.04
├── backups/
│   ├── README.md           # Backup guide: PBS and local backup
│   └── backup-job.sh       # Backup verification script
├── monitoring/
│   ├── README.md           # Monitoring guide: Prometheus + Grafana
│   └── prometheus.yml      # Prometheus config for Proxmox
├── security/
│   └── README.md           # Hardening guide
├── LICENSE                 # MIT
└── .gitignore
```

---

## Contributing

Issues and pull requests are welcome.
Keep things simple — this repo is intentionally a starter guide, not an automation framework.

## License

MIT — see [LICENSE](LICENSE).
