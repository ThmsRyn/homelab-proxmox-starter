# Security Hardening Guide — Proxmox VE 9.1

This guide covers baseline hardening for a Proxmox homelab.
Not an enterprise checklist — a practical starting point that covers the most impactful actions.

---

## Table of Contents

1. [Web UI and API Hardening](#1-web-ui-and-api-hardening)
2. [SSH Hardening](#2-ssh-hardening)
3. [Two-Factor Authentication (2FA)](#3-two-factor-authentication-2fa)
4. [User and Permission Management](#4-user-and-permission-management)
5. [Proxmox Firewall](#5-proxmox-firewall)
6. [Remove the Subscription Nag](#6-remove-the-subscription-nag)
7. [Kernel and System Hardening](#7-kernel-and-system-hardening)
8. [Audit and Logging](#8-audit-and-logging)
9. [VM Isolation](#9-vm-isolation)
10. [Checklist Summary](#10-checklist-summary)

---

## 1. Web UI and API Hardening

### Change the default port (optional, security by obscurity)

The web UI runs on port 8006 by default. Changing it does not add real security but reduces automated scanning noise.

```bash
# Edit the pveproxy config
cat >> /etc/default/pveproxy << 'EOF'
LISTEN_PORT=8443
EOF

systemctl restart pveproxy
```

If you change the port, update your firewall rules accordingly.

### Restrict web UI access to a specific subnet

The best approach is to allow the Proxmox web UI port only from your management machine or VLAN, using the Proxmox firewall (see section 5).

### Use a valid TLS certificate

The default certificate is self-signed. For a homelab, you can use Let's Encrypt with a DNS challenge if your domain is publicly resolvable — even for internal use.

```bash
# Install acme.sh or use the built-in ACME client in Proxmox
# Web UI: Datacenter > ACME > Add Account, then Node > Certificates > Add ACME Domain
```

Alternatively, generate a certificate from your own internal CA (e.g. step-ca, Easy-RSA).

---

## 2. SSH Hardening

### Disable root SSH login

Root login over SSH should be disabled. Use a non-root user or key-only root if strictly necessary.

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
```

If you need root access via SSH temporarily, prefer: `ssh thomas@pve01 sudo -i`

### Disable password authentication (keys only)

```bash
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
```

Make sure your SSH public key is in `/root/.ssh/authorized_keys` before applying this, or you will lock yourself out.

### Additional SSH hardening options

Create `/etc/ssh/sshd_config.d/99-proxmox-hardening.conf`:

```
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers thomas root
X11Forwarding no
AllowTcpForwarding no
```

Apply:

```bash
sshd -t   # test config before reloading
systemctl restart sshd
```

### Change SSH port (optional)

```bash
# Uncomment and set in /etc/ssh/sshd_config
Port 2222
```

Update firewall rules if you change the port.

---

## 3. Two-Factor Authentication (2FA)

2FA prevents account compromise if credentials are stolen. Proxmox supports TOTP natively.

### Enable 2FA for a user

1. In the web UI: **Datacenter** > **Permissions** > **Two Factor**
2. Click **Add** > **TOTP**
3. Enter the user (e.g. `thomas@pve`)
4. Scan the QR code with an authenticator app: Aegis (Android), Bitwarden Authenticator, or FreeOTP
5. Enter the current OTP to confirm
6. Click **Add**

### Enforce 2FA at the realm level

This requires all users in the realm to have 2FA configured before they can log in.

**Datacenter** > **Permissions** > **Realms** > click **pve** > **Edit** > enable **Two Factor**.

Note: set up 2FA for all users before enforcing, or you will lock them out.

### WebAuthn / hardware keys (alternative)

Proxmox 7.2+ supports WebAuthn (FIDO2/U2F). You can use a YubiKey or another hardware token.

**Datacenter** > **Permissions** > **Two Factor** > **WebAuthn Settings**

Configure the Relying Party ID (your Proxmox FQDN) and origin URL, then register your key.

---

## 4. User and Permission Management

### Never use root for daily operations

Create a dedicated admin user with only the privileges needed:

```bash
# Create a local PVE user
pveum user add thomas@pve --password 'ChangeThisPassword!'

# Create a custom role for homelab administration
pveum role add HomeLabAdmin --privs \
  "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Disk \
   VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
   VM.Console VM.Monitor VM.PowerMgmt VM.Snapshot VM.Backup \
   Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
   Pool.Allocate Sys.Audit Sys.Console Sys.Modify"

# Grant the role to the user at the root path
pveum aclmod / -user thomas@pve -role HomeLabAdmin
```

### Create read-only users for monitoring

```bash
pveum user add monitor@pve --password 'ReadOnlyPassword!'
pveum aclmod / -user monitor@pve -role PVEAuditor
```

### List current users and ACLs

```bash
pveum user list
pveum acl list
pveum role list
```

---

## 5. Proxmox Firewall

Proxmox has a built-in firewall at three levels: datacenter, node, and VM/LXC.

### Enable the datacenter firewall

**Web UI**: **Datacenter** > **Firewall** > **Options** > set **Firewall** to enabled.

Set the default policy:

| Direction | Policy |
|-----------|--------|
| Input     | DROP   |
| Output    | ACCEPT |
| Forward   | DROP   |

### Add explicit rules

Allow only necessary traffic to the node:

| Type  | Action | Source         | Dest port | Protocol | Comment                 |
|-------|--------|----------------|-----------|----------|--------------------------|
| in    | ACCEPT | 192.168.1.0/24 | 8006      | TCP      | Proxmox web UI           |
| in    | ACCEPT | 192.168.1.0/24 | 22        | TCP      | SSH                      |
| in    | ACCEPT | 192.168.1.0/24 | 3128      | TCP      | SPICE proxy (optional)   |
| in    | ACCEPT | any            | icmp      | ICMP     | Ping (optional)          |

Add rules in: **Datacenter** > **Firewall** > **Rules** > **Add**

Or via CLI:

```bash
# Allow SSH from management subnet
pvesh create /nodes/pve01/firewall/rules \
  --type in \
  --action ACCEPT \
  --source 192.168.1.0/24 \
  --dport 22 \
  --proto tcp \
  --comment "SSH from LAN"

# Allow web UI from management subnet
pvesh create /nodes/pve01/firewall/rules \
  --type in \
  --action ACCEPT \
  --source 192.168.1.0/24 \
  --dport 8006 \
  --proto tcp \
  --comment "Proxmox UI from LAN"
```

### Enable the node firewall

After adding rules: **Node** > **Firewall** > **Options** > set **Firewall** to enabled.

Do this AFTER adding your rules, or you will lock yourself out.

---

## 6. Remove the Subscription Nag

The subscription nag dialog appears on every login without a paid subscription. It is cosmetic only.

```bash
# Patch the proxmox widget toolkit JS
sed -Ezi.bak \
  "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

systemctl restart pveproxy
```

This patch is reset on each Proxmox update. Reapply after `apt dist-upgrade`.

---

## 7. Kernel and System Hardening

### Apply security-relevant sysctl settings

```bash
cat > /etc/sysctl.d/99-proxmox-hardening.conf << 'EOF'
# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Enable TCP SYN cookies (protection against SYN flood)
net.ipv4.tcp_syncookies = 1

# Log martian packets (packets with impossible source addresses)
net.ipv4.conf.all.log_martians = 1
EOF

sysctl -p /etc/sysctl.d/99-proxmox-hardening.conf
```

### Keep the system updated

```bash
# Unattended security updates
apt install -y unattended-upgrades

dpkg-reconfigure -f noninteractive unattended-upgrades
```

### Disable unnecessary services

Check which services are running:

```bash
systemctl list-units --type=service --state=running
```

Disable services you do not use:

```bash
# Example: disable rpcbind if no NFS is used
systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || true
```

---

## 8. Audit and Logging

### Proxmox task log

Every action in the web UI is logged to the task log. Access via:
- **Datacenter** > **Tasks**
- CLI: `pvesh get /nodes/$(hostname)/tasks --limit 50`

### System log

```bash
# SSH logins
journalctl -u sshd --since "24h ago"

# Authentication log
grep -E 'sshd|sudo|pam' /var/log/auth.log | tail -50

# Proxmox cluster events
journalctl -u pve-cluster -u pvedaemon -u pveproxy --since "24h ago"
```

### Install auditd (optional, for compliance)

```bash
apt install -y auditd

# Basic rules: monitor sensitive files
cat > /etc/audit/rules.d/proxmox.rules << 'EOF'
# Monitor changes to network interfaces
-w /etc/network/interfaces -p wa -k network-config

# Monitor changes to Proxmox config files
-w /etc/pve/ -p wa -k pve-config

# Monitor SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd-config

# Monitor authentication events
-w /var/log/auth.log -p wa -k auth-log
EOF

systemctl enable --now auditd
augenrules --load
```

---

## 9. VM Isolation

### Use separate VLANs per trust level

Segment your VMs so that a compromised VM cannot reach the hypervisor management interface.

- Proxmox management: VLAN 1 or a dedicated management VLAN — no VM traffic here
- Production VMs: VLAN 10
- Lab/test VMs: VLAN 40
- IoT: VLAN 20

See [../network/README.md](../network/README.md) for VLAN setup.

### Do not use privileged LXC containers unless required

Privileged LXC containers can theoretically escape to the host if a kernel vulnerability is exploited. Use unprivileged containers:

```bash
pct create ... --unprivileged 1
```

### Enable SecureBoot for VMs handling sensitive data

When creating a VM: **System** > **BIOS** > select **OVMF (UEFI)** instead of SeaBIOS. Enable SecureBoot.

---

## 10. Checklist Summary

| Action                                                   | Priority | Done |
|----------------------------------------------------------|----------|------|
| Disable subscription nag                                  | Low      |      |
| Disable enterprise apt repo, enable no-subscription       | High     |      |
| Run `apt dist-upgrade` after install                      | High     |      |
| Disable root SSH login                                    | High     |      |
| Disable SSH password authentication                       | High     |      |
| Enable 2FA for all admin accounts                         | High     |      |
| Create a non-root user for daily use                      | High     |      |
| Enable Proxmox firewall (datacenter + node level)         | High     |      |
| Restrict web UI access to management subnet only          | High     |      |
| Apply sysctl hardening                                    | Medium   |      |
| Set up VLAN segmentation (management vs VM traffic)       | Medium   |      |
| Use unprivileged LXC containers                           | Medium   |      |
| Enable unattended security updates                        | Medium   |      |
| Set up auditd                                             | Low      |      |
| Use a valid TLS certificate (internal CA or Let's Encrypt)| Low      |      |
