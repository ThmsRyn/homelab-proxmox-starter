#!/usr/bin/env bash
# backup-job.sh — Verify Proxmox backup age and report stale or missing backups
#
# For each VM and LXC on this node, checks when the last backup was created.
# Exits with code 1 and prints an alert if any backup is older than --max-age-hours.
#
# Usage:
#   bash backup-job.sh [OPTIONS]
#
# Options:
#   --storage <id>        Proxmox storage ID to check (e.g. pbs-01, backup-local)
#   --max-age-hours <n>   Alert if last backup is older than N hours (default: 26)
#   --notify-email <addr> Send alert email via sendmail (optional)
#   --exclude-vmid <id>    Skip a VMID/CTID (repeat option as needed)
#   --dry-run             Only report, do not exit with error code
#   --help                Show this help message
#
# Exit codes:
#   0   All backups are within the max-age window
#   1   One or more backups are stale or missing
#
# Requirements:
#   - Run on the Proxmox VE host as root
#   - pvesh and pvesm must be available (they are on any PVE node)
#   - sendmail optional (only required for --notify-email)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
STORAGE=""
MAX_AGE_HOURS=26
NOTIFY_EMAIL=""
DRY_RUN=false
SCRIPT_NAME="$(basename "$0")"
NODE="$(hostname)"
ALERT_LINES=()
HAS_STALE=false
EXCLUDED_VMIDS=()

# ---------------------------------------------------------------------------
# Color output
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

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_alert() { echo -e "${RED}[ALERT]${RESET} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  sed -n '/^# Usage:/,/^# Requirements:/p' "$0" | sed 's/^# //'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --storage)
        STORAGE="${2:?--storage requires a value}"
        shift 2
        ;;
      --max-age-hours)
        MAX_AGE_HOURS="${2:?--max-age-hours requires a value}"
        shift 2
        ;;
      --notify-email)
        NOTIFY_EMAIL="${2:?--notify-email requires a value}"
        shift 2
        ;;
      --exclude-vmid)
        EXCLUDED_VMIDS+=("${2:?--exclude-vmid requires a value}")
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
        echo "Unknown option: $1" >&2
        usage
        ;;
    esac
  done
}

is_excluded_vmid() {
  local vmid="$1"
  local excluded
  for excluded in "${EXCLUDED_VMIDS[@]}"; do
    if [[ "$excluded" == "$vmid" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate() {
  if [[ -z "$STORAGE" ]]; then
    echo "Error: --storage is required." >&2
    usage
  fi

  if ! [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || (( MAX_AGE_HOURS < 1 )); then
    echo "Error: --max-age-hours must be a positive integer." >&2
    exit 1
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must run as root on the Proxmox host." >&2
    exit 1
  fi

  if ! command -v pvesh &>/dev/null; then
    echo "Error: pvesh not found. This script must run on a Proxmox VE node." >&2
    exit 1
  fi

  if ! command -v pvesm &>/dev/null; then
    echo "Error: pvesm not found. This script must run on a Proxmox VE node." >&2
    exit 1
  fi

  # Verify storage exists
  if ! pvesm status | awk '{print $1}' | grep -q "^${STORAGE}$"; then
    echo "Error: storage '${STORAGE}' not found on this node." >&2
    echo "Available storage:" >&2
    pvesm status | awk 'NR>1 {print "  " $1}' >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Get list of VMIDs (VMs and LXCs) on this node
# ---------------------------------------------------------------------------
get_all_vmids() {
  {
    pvesh get /nodes/"$NODE"/qemu --output-format json 2>/dev/null \
      | python3 -c "import sys,json; [print(v['vmid']) for v in json.load(sys.stdin)]" 2>/dev/null || true
    pvesh get /nodes/"$NODE"/lxc --output-format json 2>/dev/null \
      | python3 -c "import sys,json; [print(v['vmid']) for v in json.load(sys.stdin)]" 2>/dev/null || true
  } | sort -n
}

# ---------------------------------------------------------------------------
# Get the timestamp of the latest backup for a given VMID in the storage
# Returns epoch seconds or empty string if no backup found
# ---------------------------------------------------------------------------
get_latest_backup_epoch() {
  local vmid="$1"
  # pvesm list returns lines like:
  # pbs-01:backup/vm/101/2026-04-01T03:00:00Z  ...  ctime=1743476400
  pvesm list "$STORAGE" --vmid "$vmid" 2>/dev/null \
    | awk 'NR>1 {print $NF}' \
    | grep -oP 'ctime=\K[0-9]+' \
    | sort -n \
    | tail -1
}

# ---------------------------------------------------------------------------
# Send email alert via sendmail
# ---------------------------------------------------------------------------
send_email_alert() {
  if [[ -z "$NOTIFY_EMAIL" ]]; then
    return
  fi

  if ! command -v sendmail &>/dev/null; then
    log_warn "sendmail not found — cannot send email alert."
    return
  fi

  local subject="[Proxmox Backup Alert] $NODE — stale or missing backups"
  local body
  body=$(printf "Backup alert from %s\n\nThe following VMs/LXCs have stale or missing backups:\n\n%s\n\nMax age configured: %d hours\nTimestamp: %s\n" \
    "$NODE" \
    "$(printf '%s\n' "${ALERT_LINES[@]}")" \
    "$MAX_AGE_HOURS" \
    "$(date)")

  {
    echo "To: $NOTIFY_EMAIL"
    echo "Subject: $subject"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "$body"
  } | sendmail "$NOTIFY_EMAIL"

  log_info "Alert email sent to $NOTIFY_EMAIL."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate

  log_info "Proxmox backup verification"
  log_info "Node        : $NODE"
  log_info "Storage     : $STORAGE"
  log_info "Max age     : ${MAX_AGE_HOURS}h"
  log_info "Excluded    : ${EXCLUDED_VMIDS[*]:-(none)}"
  log_info "Dry-run     : $DRY_RUN"
  echo

  local now
  now=$(date +%s)
  local max_age_seconds=$(( MAX_AGE_HOURS * 3600 ))

  mapfile -t vmids < <(get_all_vmids)

  if [[ ${#vmids[@]} -eq 0 ]]; then
    log_warn "No VMs or LXCs found on node '$NODE'."
    exit 0
  fi

  log_info "Found ${#vmids[@]} VMs/LXCs to check."
  echo

  for vmid in "${vmids[@]}"; do
    if is_excluded_vmid "$vmid"; then
      log_info "VMID $vmid skipped (--exclude-vmid)"
      continue
    fi

    local latest_epoch
    latest_epoch=$(get_latest_backup_epoch "$vmid")

    if [[ -z "$latest_epoch" ]]; then
      local msg="VMID $vmid — NO BACKUP FOUND in storage '$STORAGE'"
      log_alert "$msg"
      ALERT_LINES+=("$msg")
      HAS_STALE=true
      continue
    fi

    local age_seconds=$(( now - latest_epoch ))
    local age_hours=$(( age_seconds / 3600 ))
    local last_backup_str
    last_backup_str=$(date -d "@$latest_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$latest_epoch" '+%Y-%m-%d %H:%M:%S')

    if (( age_seconds > max_age_seconds )); then
      local msg="VMID $vmid — last backup: $last_backup_str (${age_hours}h ago — STALE, max ${MAX_AGE_HOURS}h)"
      log_alert "$msg"
      ALERT_LINES+=("$msg")
      HAS_STALE=true
    else
      log_ok "VMID $vmid — last backup: $last_backup_str (${age_hours}h ago)"
    fi
  done

  echo

  if [[ "$HAS_STALE" == true ]]; then
    log_alert "RESULT: ${#ALERT_LINES[@]} VM(s) with stale or missing backups."
    send_email_alert
    if [[ "$DRY_RUN" == false ]]; then
      exit 1
    else
      log_info "Dry-run mode: exiting with 0 despite alerts."
      exit 0
    fi
  else
    log_ok "RESULT: All ${#vmids[@]} VM(s) have backups within the ${MAX_AGE_HOURS}h window."
    exit 0
  fi
}

main "$@"
