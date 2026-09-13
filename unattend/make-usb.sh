#!/usr/bin/env bash
# Fills the unattend templates onto a USB stick.
#
# Everything this writes contains secrets. Nothing it writes belongs in git -
# it only ever writes to the destination you name.
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-}"
if [ -z "$DEST" ]; then
  echo "usage: $0 /Volumes/YOUR_USB  [--from-machine <host>]"
  echo
  echo "environment:"
  echo "  COMPUTER_NAME        e.g. SAG-AIR12-LITE-101   (required)"
  echo "  ADMIN_PASSWORD       password for the local admin  (required)"
  echo "  TAILSCALE_AUTH_KEY   tagged, reusable, pre-approved  (required)"
  echo "  ADMIN_USER           default SAGAdmin"
  echo "  TAILSCALE_TAGS       default tag:clinic-workstation"
  echo "  TIMEZONE             default Pacific Standard Time"
  echo "  WIFI_PROFILE         path to an exported WLAN profile xml (optional)"
  exit 2
fi
[ -d "$DEST" ] || { echo "destination '$DEST' is not a directory"; exit 1; }

: "${COMPUTER_NAME:?set COMPUTER_NAME}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
: "${TAILSCALE_AUTH_KEY:?set TAILSCALE_AUTH_KEY}"
ADMIN_USER="${ADMIN_USER:-SAGAdmin}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-tag:clinic-workstation}"
TIMEZONE="${TIMEZONE:-Pacific Standard Time}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1}"

fill() {  # fill <template> <output>
  sed -e "s|{{COMPUTER_NAME}}|$COMPUTER_NAME|g" \
      -e "s|{{ADMIN_USER}}|$ADMIN_USER|g" \
      -e "s|{{ADMIN_PASSWORD}}|$ADMIN_PASSWORD|g" \
      -e "s|{{TAILSCALE_AUTH_KEY}}|$TAILSCALE_AUTH_KEY|g" \
      -e "s|{{TAILSCALE_TAGS}}|$TAILSCALE_TAGS|g" \
      -e "s|{{TIMEZONE}}|$TIMEZONE|g" \
      -e "s|{{BOOTSTRAP_URL}}|$BOOTSTRAP_URL|g" \
      "$1" > "$2"
}

mkdir -p "$DEST/fleet"
umask 077
fill autounattend.template.xml "$DEST/Autounattend.xml"
fill setup.template.ps1        "$DEST/fleet/setup.ps1"

if [ -n "${WIFI_PROFILE:-}" ]; then
  [ -f "$WIFI_PROFILE" ] || { echo "WIFI_PROFILE '$WIFI_PROFILE' not found"; exit 1; }
  cp "$WIFI_PROFILE" "$DEST/fleet/wifi.xml"
  echo "  wifi profile copied (contains the network key in plaintext)"
fi

# Fail loudly rather than shipping a stick that silently does nothing.
if grep -q '{{' "$DEST/Autounattend.xml" "$DEST/fleet/setup.ps1"; then
  echo "ERROR: unfilled placeholders remain:"; grep -o '{{[A-Z_]*}}' "$DEST/Autounattend.xml" "$DEST/fleet/setup.ps1" | sort -u
  exit 1
fi

cat <<EOF

wrote to $DEST
  Autounattend.xml          computer name: $COMPUTER_NAME
  fleet/setup.ps1           first-logon script
$( [ -n "${WIFI_PROFILE:-}" ] && echo "  fleet/wifi.xml            wlan profile" )

This stick now holds the local admin password, the Tailscale auth key and the
wifi key in plaintext. Treat it as a credential: keep it with you, and rotate
the Tailscale key when you are done provisioning.

Plug it in BEFORE the machine's first boot, then power on and walk away.
EOF
