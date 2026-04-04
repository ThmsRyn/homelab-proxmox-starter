# VMs and Templates Guide — Proxmox VE 9.1

This guide covers VM creation, cloud-init configuration, template creation, and fast cloning.

---

## Table of Contents

1. [VM Storage Options](#1-vm-storage-options)
2. [Create a VM via the Web UI](#2-create-a-vm-via-the-web-ui)
3. [Create a VM via CLI (qm)](#3-create-a-vm-via-cli-qm)
4. [Cloud-Init Overview](#4-cloud-init-overview)
5. [Prepare a Cloud-Init Ready VM](#5-prepare-a-cloud-init-ready-vm)
6. [Convert to Template](#6-convert-to-template)
7. [Clone a Template](#7-clone-a-template)
8. [Import a Cloud Image (Faster Method)](#8-import-a-cloud-image-faster-method)
9. [VM Configuration Reference](#9-vm-configuration-reference)
10. [Snapshots](#10-snapshots)

---

## 1. VM Storage Options

Proxmox supports multiple storage backends. The most common:

| Backend        | Format       | Snapshots | Notes                           |
|---------------|--------------|-----------|----------------------------------|
| LVM-Thin       | raw          | Yes       | Default after installation       |
| ZFS            | zvol / qcow2 | Yes       | Best option if you have NVMe     |
| Directory      | qcow2, raw   | Yes (qcow2)| Simple, works on any filesystem |
| NFS/CIFS       | qcow2, raw   | Yes (qcow2)| For shared storage               |

Use LVM-Thin or ZFS for the best snapshot performance.

---

## 2. Create a VM via the Web UI

1. Click **Create VM** in the top-right of the web UI.
2. **General**: set Node, VM ID (e.g. 100), Name.
3. **OS**: select ISO image from local storage. Set OS type to Linux, version 6.x kernel.
4. **System**: leave defaults (BIOS: SeaBIOS or OVMF for UEFI). Enable QEMU Agent.
5. **Disks**: select storage (local-lvm or ZFS pool). Set size. Disk bus: SCSI, controller: VirtIO SCSI Single.
6. **CPU**: set cores. Type: `host` for best performance.
7. **Memory**: set RAM. Enable ballooning for dynamic memory.
8. **Network**: model `VirtIO (paravirt)`, bridge `vmbr0`. Set VLAN tag if needed.
9. **Confirm**: review and click **Finish**.

---

## 3. Create a VM via CLI (qm)

The `qm` command manages virtual machines from the shell.

### Minimal Ubuntu 24.04 VM

```bash
qm create 101 \
  --name ubuntu-2404-base \
  --memory 2048 \
  --balloon 1024 \
  --cores 2 \
  --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32,discard=on,ssd=1 \
  --ide2 local:iso/ubuntu-24.04.4-live-server-amd64.iso,media=cdrom \
  --boot order=ide2 \
  --agent enabled=1 \
  --onboot 0
```

Key flags:

- `--cpu host`: exposes full CPU feature set to the VM.
- `--balloon 1024`: minimum memory for ballooning (requires balloon driver inside VM).
- `--scsihw virtio-scsi-single`: modern, high-performance SCSI controller.
- `--discard=on,ssd=1`: enables TRIM/discard passthrough (important for SSDs and LVM-Thin).
- `--agent enabled=1`: enables QEMU guest agent socket.
- `--onboot 0`: do not start automatically (set to 1 for production VMs).

### Start the VM and open the console

```bash
qm start 101
# Then open the web console or use:
pvesh get /nodes/$(hostname)/vms/101/termproxy --shell 1
```

---

## 4. Cloud-Init Overview

Cloud-init is the standard for initialising cloud instances. On first boot it:

- Sets the hostname
- Creates users and injects SSH keys
- Configures networking (DHCP or static IP)
- Runs custom scripts

Proxmox supports cloud-init natively via a special drive (virtio, IDE, or SCSI). The VM reads this drive on boot like a data CD.

Supported cloud-init parameters in Proxmox:

| `qm set` flag        | Effect                                      |
|---------------------|---------------------------------------------|
| `--ciuser`          | Default user name                           |
| `--cipassword`      | Password for the default user               |
| `--sshkeys`         | Authorised SSH public keys                  |
| `--ipconfig0`       | Network config for net0 (ip=dhcp or static) |
| `--nameserver`      | DNS server                                  |
| `--searchdomain`    | DNS search domain                           |
| `--cicustom`        | Path to a custom cloud-init YAML file       |

---

## 5. Prepare a Cloud-Init Ready VM

### Download the Ubuntu 24.04 cloud image

```bash
wget -P /var/lib/vz/template/iso/ \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

This is a pre-built cloud image with cloud-init already installed. It is much faster than installing from the server ISO.

### Create the base VM

```bash
qm create 9000 \
  --name ubuntu-2404-cloud \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --agent enabled=1
```

### Import the cloud image as the primary disk

```bash
qm importdisk 9000 \
  /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
  local-lvm

# Attach it as scsi0
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,discard=on,ssd=1
```

### Add cloud-init drive and configure boot

```bash
# Cloud-init drive on IDE channel 1
qm set 9000 --ide1 local-lvm:cloudinit

# Boot order: disk first
qm set 9000 --boot order=scsi0

# Serial console (needed for cloud-init to work properly)
qm set 9000 --serial0 socket --vga serial0
```

### Set cloud-init defaults

```bash
qm set 9000 \
  --ciuser thomas \
  --sshkeys /root/.ssh/authorized_keys \
  --ipconfig0 ip=dhcp \
  --nameserver 1.1.1.1 \
  --searchdomain lab.local
```

See [cloud-init.yaml](cloud-init.yaml) for a full custom cloud-init configuration.

To use a custom file:

```bash
# Place the file in a Proxmox snippets storage (a directory storage with 'snippets' content enabled)
cp cloud-init.yaml /var/lib/vz/snippets/ubuntu-base.yaml

qm set 9000 --cicustom "user=local:snippets/ubuntu-base.yaml"
```

### Resize the disk (cloud images start at ~3 GB)

```bash
qm resize 9000 scsi0 +29G
# Result: 32 GB total
```

---

## 6. Convert to Template

Once the base VM is configured and the disk is clean:

```bash
qm template 9000
```

After this, the VM is read-only. You can no longer start it directly — only clone it.

To update the template in the future: clone it, make changes, re-convert to template (delete the old one first).

---

## 7. Clone a Template

### Linked clone (fast, shares base disk — less storage)

```bash
qm clone 9000 201 --name webserver-01
```

A linked clone shares the base disk blocks and only stores differences. Faster to create, but tied to the template — you cannot delete the template while linked clones exist.

### Full clone (independent — recommended for production)

```bash
qm clone 9000 202 --name db-01 --full
```

Full clones are completely independent. Delete or update the template freely.

### Override cloud-init settings per clone

```bash
qm set 202 \
  --ipconfig0 ip=192.168.1.50/24,gw=192.168.1.1 \
  --ciuser admin

# Regenerate the cloud-init drive
qm cloudinit dump 202 user
```

Start the clone:

```bash
qm start 202
```

---

## 8. Import a Cloud Image (Faster Method)

If you already have the image locally:

```bash
# Download directly to the right location
wget -q --show-progress \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O /tmp/noble-server-cloudimg-amd64.img

# Create VM + import in one shot
VMID=9001
qm create $VMID --name ubuntu-noble-template --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-single --agent enabled=1
qm importdisk $VMID /tmp/noble-server-cloudimg-amd64.img local-lvm
qm set $VMID \
  --scsi0 local-lvm:vm-${VMID}-disk-0,discard=on,ssd=1 \
  --ide1 local-lvm:cloudinit \
  --boot order=scsi0 \
  --serial0 socket --vga serial0 \
  --ciuser thomas \
  --sshkeys /root/.ssh/authorized_keys \
  --ipconfig0 ip=dhcp
qm resize $VMID scsi0 +29G
qm template $VMID
```

---

## 9. VM Configuration Reference

```bash
# Show full config
qm config <vmid>

# Modify CPU and RAM without stopping
qm set <vmid> --memory 4096
qm set <vmid> --cores 4

# Add a second disk
qm set <vmid> --scsi1 local-lvm:20

# Hotplug a USB device
qm set <vmid> --usb0 host=<vendorid>:<productid>

# Enable start on boot
qm set <vmid> --onboot 1

# Set startup order (lower = earlier)
qm set <vmid> --startup order=1,up=30,down=60

# Protect from accidental deletion
qm set <vmid> --protection 1
```

---

## 10. Snapshots

Snapshots capture the VM state (disk + optionally memory) at a point in time.

```bash
# Create a snapshot (disk only — VM can be running with QEMU agent)
qm snapshot <vmid> snap-$(date +%Y%m%d) --description "Before update"

# Create snapshot including RAM state (VM must be running)
qm snapshot <vmid> snap-with-ram --vmstate 1

# List snapshots
qm listsnapshot <vmid>

# Rollback
qm rollback <vmid> snap-20260401

# Delete snapshot
qm delsnapshot <vmid> snap-20260401
```

Note: snapshots on LVM-Thin are fast and efficient. On raw LVM without thin provisioning, snapshots are not supported.
