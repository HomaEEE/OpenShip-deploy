#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_FILE="/var/log/openship-control-update.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "$CYAN[INFO]$NC $*"; }
ok() { echo -e "$GREEN[ OK ]$NC $*"; }
warn() { echo -e "$YELLOW[WARN]$NC $*"; }
die() { echo -e "$RED[ERROR]$NC $*" >&2; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
    die "Run as root: sudo ./update.sh"
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "============================================================"
echo " OpenShip Control Plane — Update"
echo "============================================================"
echo

command -v openship >/dev/null 2>&1 || die "OpenShip CLI is not installed."

log "Current version:"
openship --version || true

echo
if [[ $# -ge 1 && "$1" == "--check" ]]; then
    log "Checking for updates..."
    openship update --check
    exit $?
fi

if [[ $# -gt 0 ]]; then
    die "Usage: sudo ./update.sh [--check]"
fi

echo
warn "OpenShip will update the CLI and bundled server."
warn "The running OpenShip service may be restarted."
echo

read -r -p "Continue? [y/N]: " answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) log "Update cancelled."; exit 0 ;;
esac

echo
log "Updating OpenShip..."
openship update

echo
log "Version after update:"
openship --version || true

echo
log "OpenShip status:"
openship status || true

echo
log "OpenShip doctor:"
if openship doctor; then
    ok "OpenShip update and health check completed."
else
    warn "OpenShip was updated, but doctor reported a problem."
    warn "Run: sudo ./doctor.sh"
    exit 2
fi

echo
echo "Log: $LOG_FILE"
