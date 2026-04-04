# Network Guide — Proxmox VE 9.1

This guide covers network configuration for a homelab Proxmox setup:
bridges, VLANs, trunk ports, and an optional pfSense VM as the network gateway.

---

## Table of Contents

1. [How Proxmox Networking Works](#1-how-proxmox-networking-works)
2. [Linux Bridges](#2-linux-bridges)
3. [VLAN Overview](#3-vlan-overview)
4. [VLAN-Aware Bridge Setup](#4-vlan-aware-bridge-setup)
5. [Trunk Port to a Managed Switch](#5-trunk-port-to-a-managed-switch)
6. [Assigning VMs to VLANs](#6-assigning-vms-to-vlans)
7. [pfSense as a VM Gateway](#7-pfsense-as-a-vm-gateway)
8. [Bonding and Link Aggregation](#8-bonding-and-link-aggregation)
9. [Useful Network Commands](#9-useful-network-commands)

---

## 1. How Proxmox Networking Works

Proxmox uses standard Linux networking. There is no proprietary abstraction. The main file is:

```
/etc/network/interfaces
```

Changes made in the web UI (Node > Network) write to this file. Changes are applied with `ifreload -a` or on reboot.

Key concepts:

- **Physical NIC** (`eno1`, `enp3s0`, etc.): the real hardware interface. Set to `manual` — Proxmox bridges own the IP.
- **Linux bridge** (`vmbr0`, `vmbr1`, etc.): virtual switch. VMs plug into bridges, not directly into NICs.
- **VLAN interface** (`vmbr0.10`, `eno1.10`): tagged sub-interface for a specific VLAN.
- **Bond** (`bond0`): aggregates 2+ physical NICs into one logical link.

---

## 2. Linux Bridges

### Default bridge (vmbr0)

Created during installation. Carries the Proxmox management IP.

```
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

`bridge-stp off` and `bridge-fd 0` are important: they prevent the 15-second STP forwarding delay on startup.

### Adding a second bridge (isolated internal network)

```
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # No physical port: internal-only traffic between VMs
```

Apply:

```bash
ifreload -a
```

---

## 3. VLAN Overview

VLANs let you segment traffic on a single physical link. Each VLAN has an ID (1–4094). Traffic is tagged with an 802.1Q header.

Common homelab VLAN layout:

| VLAN ID | Name         | Purpose                        |
|---------|--------------|--------------------------------|
| 1       | Native/Mgmt  | Proxmox management, hypervisor |
| 10      | LAN          | Trusted devices, desktops      |
| 20      | IoT          | Smart home devices             |
| 30      | DMZ          | Public-facing services         |
| 40      | Lab          | Experimental VMs               |

---

## 4. VLAN-Aware Bridge Setup

Proxmox supports VLAN-aware bridges natively since PVE 4.x. This is the recommended approach.

### Manual edit of /etc/network/interfaces

```
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

`bridge-vlan-aware yes` enables 802.1Q tagging on this bridge.
`bridge-vids 2-4094` declares all VLANs as allowed. You can restrict to specific IDs if needed.

Apply:

```bash
ifreload -a
```

Verify:

```bash
bridge vlan show
```

For automated setup, use the provided script:

```bash
bash network/vlan-setup.sh --bridge vmbr0 --vlans 10,20,30,40 --dry-run
```

Remove `--dry-run` to apply.

---

## 5. Trunk Port to a Managed Switch

For VLANs to reach other devices on your network, your managed switch must have the Proxmox port configured as a **trunk** (carries all tagged VLANs).

### Cisco-style configuration (example)

```
interface GigabitEthernet0/1
  description Proxmox-PVE01
  switchport mode trunk
  switchport trunk allowed vlan 1,10,20,30,40
  spanning-tree portfast trunk
```

### TP-Link / UniFi / Netgear

Set the port connecting to Proxmox as **Tagged** for all VLANs you want to pass through.

The Proxmox management VLAN (VLAN 1 by default) should be the **native** VLAN (untagged) on the trunk port so the Proxmox host itself remains accessible.

---

## 6. Assigning VMs to VLANs

With a VLAN-aware bridge, you tag VMs individually. No extra bridge per VLAN needed.

### In the web UI

When creating or editing a VM: **Hardware** > **Network Device** > set **VLAN Tag** to the desired VLAN ID.

### Via CLI (qm set)

```bash
# Assign VM 201 to VLAN 10
qm set 201 --net0 virtio,bridge=vmbr0,tag=10

# Assign LXC 200 to VLAN 20
pct set 200 --net0 name=eth0,bridge=vmbr0,tag=20,ip=dhcp
```

The VM sees an untagged interface (the hypervisor handles the tagging). No changes needed inside the VM.

---

## 7. pfSense as a VM Gateway

pfSense or OPNsense running as a VM provides routing and firewall between VLANs.

### Architecture

```
Internet (WAN)
    |
[Physical NIC eno2] -- vmbr-wan (bridge, no IP)
    |
[pfSense VM]
    |
[vmbr0, VLAN-aware] -- internal VLANs (LAN, IoT, DMZ, Lab)
```

pfSense gets:
- A WAN interface: plugged into `vmbr-wan` (connected to your router or modem)
- A LAN interface: plugged into `vmbr0` with a VLAN trunk

pfSense then handles inter-VLAN routing and firewall rules.

### Create the WAN bridge

```
auto vmbr-wan
iface vmbr-wan inet manual
    bridge-ports eno2
    bridge-stp off
    bridge-fd 0
```

### pfSense VM configuration

```bash
qm create 300 \
  --name pfsense \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr-wan \
  --net1 virtio,bridge=vmbr0 \
  --ostype other \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:16
```

Inside pfSense, configure net1 as a VLAN trunk and create VLAN interfaces for each VLAN ID.

---

## 8. Bonding and Link Aggregation

If your server has 2+ NICs, you can bond them for redundancy or increased throughput.

### Active-backup bond (redundancy)

```
auto bond0
iface bond0 inet manual
    bond-slaves eno1 eno2
    bond-miimon 100
    bond-mode active-backup
    bond-primary eno1

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

`bond-miimon 100` checks link state every 100ms. If `eno1` fails, traffic switches to `eno2` automatically.

### LACP / 802.3ad (requires managed switch support)

```
auto bond0
iface bond0 inet manual
    bond-slaves eno1 eno2
    bond-miimon 100
    bond-mode 802.3ad
    bond-lacp-rate fast
    bond-xmit-hash-policy layer2+3
```

Configure the corresponding port-channel on your switch.

---

## 9. Useful Network Commands

```bash
# Show all interfaces and their state
ip link show

# Show IP addresses
ip addr show

# Show bridge details (ports, VLANs)
bridge link show
bridge vlan show

# Reload network config without full reboot
ifreload -a

# Show the current routing table
ip route show

# Test connectivity between VMs on different VLANs
ping -c 3 -I vmbr0.10 192.168.10.1

# Show bond status (if bonding is configured)
cat /proc/net/bonding/bond0

# Capture traffic on a bridge port (tcpdump)
tcpdump -i vmbr0 -n -v 'vlan 10'
```
