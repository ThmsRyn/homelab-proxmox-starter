#!/usr/bin/env bash
# vlan-setup.sh — Configure VLAN-aware bridge on Proxmox VE 9.1
#
# Modifies /etc/network/interfaces to:
#   1. Enable bridge-vlan-aware on the target bridge
#   2. Set the allowed VLAN range (bridge-vids)
#   3. Create VLAN sub-interfaces on the bridge for host-level VLAN access
#
# Usage:
#   bash vlan-setup.sh [OPTIONS]
#
# Options:
#   --bridge <name>     Bridge to configure (default: vmbr0)
#   --vlans <list>      Comma-separated VLAN IDs to configure (e.g. 10,20,30)
#   --iface-file <path> Path to interfaces file (default: /etc/network/interfaces)
#   --dry-run           Print what would be done, do not modify any file
#   --help              Show this help message
#
# Examples:
#   bash vlan-setup.sh --bridge vmbr0 --vlans 10,20,30 --dry-run
#   bash vlan-setup.sh --bridge vmbr0 --vlans 10,20,30,40

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BRIDGE="vmbr0"
VLANS=""
IFACE_FILE="/etc/network/interfaces"
DRY_RUN=false
BACKUP_SUFFIX=".bak.$(date +%Y%m%d_%H%M%S)"

# ---------------------------------------------------------------------------
# Color output (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' RESET=''
fi

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_dryrun()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | head -n 30 | sed 's/^# //'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bridge)
        BRIDGE="${2:?--bridge requires a value}"
        shift 2
        ;;
      --vlans)
        VLANS="${2:?--vlans requires a value}"
        shift 2
        ;;
      --iface-file)
        IFACE_FILE="${2:?--iface-file requires a value}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_args() {
  if [[ -z "$VLANS" ]]; then
    log_error "--vlans is required. Example: --vlans 10,20,30"
    exit 1
  fi

  if [[ ! -f "$IFACE_FILE" ]]; then
    log_error "Interfaces file not found: $IFACE_FILE"
    exit 1
  fi

  # Validate VLAN IDs
  IFS=',' read -ra VLAN_ARRAY <<< "$VLANS"
  for vlan in "${VLAN_ARRAY[@]}"; do
    if ! [[ "$vlan" =~ ^[0-9]+$ ]] || (( vlan < 1 || vlan > 4094 )); then
      log_error "Invalid VLAN ID: $vlan (must be 1–4094)"
      exit 1
    fi
  done

  # Check we are running on Linux (Proxmox is Linux only)
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_error "This script is designed for Linux / Proxmox VE only."
    exit 1
  fi

  # Warn if not root (changes to /etc/network/interfaces require root)
  if [[ $EUID -ne 0 ]] && [[ "$DRY_RUN" == false ]]; then
    log_warn "Not running as root. Changes to $IFACE_FILE will likely fail."
    log_warn "Run with sudo or as root, or use --dry-run to preview changes."
  fi

  log_ok "Arguments validated."
}

# ---------------------------------------------------------------------------
# Check if the bridge exists in the interfaces file
# ---------------------------------------------------------------------------
bridge_exists_in_file() {
  grep -q "^auto ${BRIDGE}$" "$IFACE_FILE" || grep -q "^iface ${BRIDGE} " "$IFACE_FILE"
}

# ---------------------------------------------------------------------------
# Check if a specific VLAN sub-interface stanza already exists
# ---------------------------------------------------------------------------
vlan_iface_exists() {
  local vlan_id="$1"
  grep -q "^auto ${BRIDGE}.${vlan_id}$" "$IFACE_FILE"
}

# ---------------------------------------------------------------------------
# Build the patch for bridge-vlan-aware and bridge-vids
# This function prints the modified block for the target bridge.
# We use awk to insert the options after the last existing bridge-* line
# inside the bridge stanza.
# ---------------------------------------------------------------------------
patch_bridge_stanza() {
  local tmpfile
  tmpfile=$(mktemp)

  awk -v bridge="$BRIDGE" '
    BEGIN {
      in_bridge = 0
      vlan_aware_added = 0
      bridge_vids_added = 0
    }

    /^(auto|iface|allow-hotplug)/ {
      # Entering a new stanza: flush pending additions for previous bridge
      if (in_bridge && !vlan_aware_added) {
        print "    bridge-vlan-aware yes"
        print "    bridge-vids 2-4094"
        vlan_aware_added = 1
        bridge_vids_added = 1
      }
      in_bridge = 0
      vlan_aware_added = 0
      bridge_vids_added = 0
    }

    /^iface[[:space:]]/ && $2 == bridge {
      in_bridge = 1
    }

    in_bridge && /bridge-vlan-aware/ {
      # Already present: normalise the value
      sub(/bridge-vlan-aware[[:space:]]+.*/, "bridge-vlan-aware yes")
      vlan_aware_added = 1
      print
      next
    }

    in_bridge && /bridge-vids/ {
      # Already present: normalise the value
      sub(/bridge-vids[[:space:]]+.*/, "bridge-vids 2-4094")
      bridge_vids_added = 1
      print
      next
    }

    in_bridge && /bridge-fd/ && !vlan_aware_added {
      # Insert after bridge-fd
      print
      print "    bridge-vlan-aware yes"
      print "    bridge-vids 2-4094"
      vlan_aware_added = 1
      bridge_vids_added = 1
      next
    }

    { print }

    END {
      if (in_bridge && !vlan_aware_added) {
        print "    bridge-vlan-aware yes"
        print "    bridge-vids 2-4094"
      }
    }
  ' "$IFACE_FILE" > "$tmpfile"

  echo "$tmpfile"
}

# ---------------------------------------------------------------------------
# Build stanzas for VLAN sub-interfaces (host-level VLAN access)
# These are manual interfaces — no IP assigned here.
# Assign IPs at the VM/LXC level or add them manually afterward.
# ---------------------------------------------------------------------------
build_vlan_stanzas() {
  local output=""
  IFS=',' read -ra VLAN_ARRAY <<< "$VLANS"
  for vlan in "${VLAN_ARRAY[@]}"; do
    if ! vlan_iface_exists "$vlan"; then
      output+="
auto ${BRIDGE}.${vlan}
iface ${BRIDGE}.${vlan} inet manual
    # VLAN ${vlan} sub-interface on ${BRIDGE}
    # Assign an IP here if the Proxmox host needs to communicate on VLAN ${vlan}
    # Example: address 192.168.${vlan}.1/24
"
    else
      log_warn "VLAN sub-interface ${BRIDGE}.${vlan} already exists in $IFACE_FILE — skipped."
    fi
  done
  echo "$output"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  log_info "Proxmox VE VLAN setup script"
  log_info "Bridge  : $BRIDGE"
  log_info "VLANs   : $VLANS"
  log_info "File    : $IFACE_FILE"
  log_info "Dry-run : $DRY_RUN"
  echo

  validate_args

  # Check bridge exists in file
  if ! bridge_exists_in_file; then
    log_error "Bridge '$BRIDGE' not found in $IFACE_FILE."
    log_error "Create the bridge first via the Proxmox web UI or manually."
    exit 1
  fi

  log_info "Bridge '$BRIDGE' found in $IFACE_FILE."

  # Build patched bridge stanza
  local patched_file
  patched_file=$(patch_bridge_stanza)

  # Build VLAN stanzas
  local vlan_stanzas
  vlan_stanzas=$(build_vlan_stanzas)

  if [[ "$DRY_RUN" == true ]]; then
    echo
    log_dryrun "--- Patched $IFACE_FILE (bridge section) ---"
    cat "$patched_file"
    echo
    if [[ -n "$vlan_stanzas" ]]; then
      log_dryrun "--- VLAN sub-interfaces to append ---"
      echo "$vlan_stanzas"
    fi
    log_dryrun "No changes written (--dry-run mode)."
    rm -f "$patched_file"
    exit 0
  fi

  # Backup original file
  cp "$IFACE_FILE" "${IFACE_FILE}${BACKUP_SUFFIX}"
  log_ok "Backup created: ${IFACE_FILE}${BACKUP_SUFFIX}"

  # Write patched bridge stanza
  cp "$patched_file" "$IFACE_FILE"
  rm -f "$patched_file"
  log_ok "Bridge stanza patched (bridge-vlan-aware yes, bridge-vids 2-4094)."

  # Append VLAN stanzas
  if [[ -n "$vlan_stanzas" ]]; then
    echo "$vlan_stanzas" >> "$IFACE_FILE"
    log_ok "VLAN sub-interfaces appended."
  fi

  # Apply changes
  log_info "Applying network configuration with ifreload..."
  if command -v ifreload &>/dev/null; then
    ifreload -a && log_ok "Network configuration applied."
  else
    # WARNING: never run this on vmbr0 (management bridge) — it will cut your SSH session
    log_warn "ifreload not found. Reboot to apply changes, or run: ifdown $BRIDGE && ifup $BRIDGE"
  fi

  echo
  log_ok "Done. Verify with: bridge vlan show"
  echo
  log_info "To assign a VM to a VLAN, run:"
  log_info "  qm set <vmid> --net0 virtio,bridge=${BRIDGE},tag=<vlan_id>"
  log_info "To assign an LXC to a VLAN, run:"
  log_info "  pct set <ctid> --net0 name=eth0,bridge=${BRIDGE},tag=<vlan_id>,ip=dhcp"
}

main "$@"
