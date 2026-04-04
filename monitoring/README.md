# Monitoring Guide — Proxmox VE 9.1

This guide sets up monitoring for a Proxmox homelab using:

- **prometheus-pve-exporter**: exposes Proxmox API metrics (VMs, nodes, storage, cluster)
- **node_exporter**: exposes host-level OS metrics (CPU, RAM, disk, network)
- **Prometheus**: scrapes and stores metrics
- **Grafana**: dashboards

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Create the Monitoring VM or LXC](#2-create-the-monitoring-vm-or-lxc)
3. [Install prometheus-pve-exporter](#3-install-prometheus-pve-exporter)
4. [Install node_exporter on Proxmox Hosts](#4-install-node_exporter-on-proxmox-hosts)
5. [Install Prometheus](#5-install-prometheus)
6. [Configure Prometheus](#6-configure-prometheus)
7. [Install Grafana](#7-install-grafana)
8. [Import Dashboards](#8-import-dashboards)
9. [Alerting with Alertmanager (Optional)](#9-alerting-with-alertmanager-optional)
10. [Useful Queries (PromQL)](#10-useful-queries-promql)

---

## 1. Architecture Overview

```
Proxmox Node(s)
  |- node_exporter        :9100  (host OS metrics)
  |- pve-exporter         :9221  (Proxmox API metrics, runs on monitoring VM or node)

Monitoring VM / LXC
  |- Prometheus           :9090  (scrapes exporters, stores TSDB)
  |- Grafana              :3000  (reads Prometheus, renders dashboards)
  |- Alertmanager         :9093  (optional, handles alert routing)
```

All components run on a single monitoring VM or LXC.
The Proxmox API is scraped remotely — no agent on the hypervisor beyond node_exporter.

---

## 2. Create the Monitoring VM or LXC

A lightweight LXC is sufficient:

```bash
pct create 150 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname monitoring \
  --memory 1024 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.15/24,gw=192.168.1.1 \
  --storage local-lvm \
  --rootfs local-lvm:10 \
  --unprivileged 1 \
  --onboot 1 \
  --start 1
```

Update the system:

```bash
pct enter 150
apt update && apt upgrade -y
```

---

## 3. Install prometheus-pve-exporter

`prometheus-pve-exporter` is a Python application that queries the Proxmox API and exposes metrics in Prometheus format.

Source: [https://github.com/prometheus-pve/prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter)

### Install on the monitoring LXC

```bash
apt install -y python3-pip python3-venv

python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install prometheus-pve-exporter
```

### Create a read-only Proxmox user for the exporter

On the Proxmox host (not the monitoring LXC):

```bash
pveum user add pve-exporter@pve --password 'ExporterReadOnly1!'
pveum role add PVEExporterRole --privs "Sys.Audit VM.Audit Datastore.Audit Pool.Audit"
pveum aclmod / -user pve-exporter@pve -role PVEExporterRole
```

### Configure the exporter

On the monitoring LXC:

```bash
mkdir -p /etc/prometheus
cat > /etc/prometheus/pve.yml << 'EOF'
default:
  user: pve-exporter@pve
  password: ExporterReadOnly1!
  verify_ssl: false
EOF

chmod 600 /etc/prometheus/pve.yml
```

### Create a systemd service

```bash
cat > /etc/systemd/system/prometheus-pve-exporter.service << 'EOF'
[Unit]
Description=Prometheus Proxmox VE Exporter
Documentation=https://github.com/prometheus-pve/prometheus-pve-exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/opt/pve-exporter/bin/pve_exporter \
  --config.file=/etc/prometheus/pve.yml \
  --web.listen-address=0.0.0.0:9221
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus-pve-exporter
```

Verify:

```bash
curl -s "http://localhost:9221/pve?target=192.168.1.10&module=default" | head -20
```

Replace `192.168.1.10` with your Proxmox node IP.

---

## 4. Install node_exporter on Proxmox Hosts

`node_exporter` exposes OS-level metrics from the Proxmox host itself.

Run this on each Proxmox node (not the monitoring LXC):

```bash
# Download node_exporter
NODE_EXPORTER_VERSION="1.8.2"
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/node_exporter.tar.gz

tar -xzf /tmp/node_exporter.tar.gz -C /tmp
cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

# Create system user
useradd --no-create-home --shell /bin/false node_exporter

# Create systemd service
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.diskstats \
  --collector.filesystem \
  --collector.loadavg \
  --collector.meminfo \
  --collector.netdev \
  --collector.time \
  --collector.vmstat \
  --web.listen-address=0.0.0.0:9100
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
```

Verify:

```bash
curl -s http://localhost:9100/metrics | grep node_cpu_seconds_total | head -5
```

---

## 5. Install Prometheus

On the monitoring LXC:

```bash
apt install -y prometheus
systemctl enable prometheus
```

The default Prometheus config is at `/etc/prometheus/prometheus.yml`.
Replace it with the config from this repo.

---

## 6. Configure Prometheus

Copy the provided config:

```bash
cp prometheus.yml /etc/prometheus/prometheus.yml
systemctl restart prometheus
```

See [prometheus.yml](prometheus.yml) for the full configuration.

Key targets in the config:

| Job                     | Port | Source                          |
|------------------------|------|----------------------------------|
| `pve-node`              | 9221 | Proxmox API via pve-exporter     |
| `node-pve`              | 9100 | Proxmox host OS via node_exporter|
| `prometheus`            | 9090 | Prometheus self-monitoring       |

Verify Prometheus targets at `http://192.168.1.15:9090/targets`.

All targets should show **UP**.

---

## 7. Install Grafana

On the monitoring LXC:

```bash
apt install -y apt-transport-https software-properties-common wget gnupg

mkdir -p /usr/share/keyrings
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key

echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

apt update && apt install -y grafana

systemctl enable --now grafana-server
```

Access Grafana at `http://192.168.1.15:3000`.

Default credentials: `admin` / `admin`. Change on first login.

### Add Prometheus as a data source

1. In Grafana: **Connections** > **Data Sources** > **Add data source** > **Prometheus**
2. URL: `http://localhost:9090`
3. Click **Save & Test**. Should return "Data source is working".

---

## 8. Import Dashboards

### Proxmox VE dashboard (via pve-exporter)

Dashboard ID: **10347**

1. In Grafana: **Dashboards** > **Import**
2. Enter ID `10347`, click **Load**
3. Select your Prometheus data source
4. Click **Import**

This dashboard shows: node status, VM count, CPU/RAM per VM, storage usage, network I/O.

### Node Exporter Full (host OS metrics)

Dashboard ID: **1860**

Same import process. Shows detailed CPU, memory, disk, and network metrics from node_exporter.

### Proxmox Cluster Dashboard

Dashboard ID: **15356** — useful if you have multiple Proxmox nodes in a cluster.

---

## 9. Alerting with Alertmanager (Optional)

Alertmanager handles routing, grouping, and sending of alerts from Prometheus.

```bash
apt install -y prometheus-alertmanager
systemctl enable --now prometheus-alertmanager
```

Example alert rule — create `/etc/prometheus/alerts/proxmox.yml`:

```yaml
groups:
  - name: proxmox
    rules:
      - alert: ProxmoxNodeDown
        expr: up{job="node-pve"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Proxmox node unreachable"
          description: "node_exporter on {{ $labels.instance }} has been down for 2 minutes."

      - alert: ProxmoxHighCPU
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Proxmox high CPU usage"
          description: "CPU usage on {{ $labels.instance }} is above 90% for 5 minutes."

      - alert: ProxmoxLowDisk
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 10
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Proxmox root disk almost full"
          description: "Less than 10% free disk space on {{ $labels.instance }}."
```

Add the rule file reference to `prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/alerts/*.yml
```

---

## 10. Useful Queries (PromQL)

```promql
# Proxmox node CPU usage (%)
100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100

# Memory used (%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk space used on root (%)
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Number of running VMs on the cluster
pve_up{type="qemu"}

# VM CPU usage
rate(pve_cpu_usage_ratio{type="qemu"}[5m]) * 100

# Storage usage per pool
pve_disk_usage_bytes / pve_disk_size_bytes * 100

# Network receive rate per interface (bytes/s)
rate(node_network_receive_bytes_total[5m])
```
