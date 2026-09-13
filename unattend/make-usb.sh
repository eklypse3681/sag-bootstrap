#!/usr/bin/env bash
# Fills the unattend templates onto a USB stick.
#
# Settings come from (highest precedence first): the environment, then .env,
# then an interactive prompt for the computer name. Everything this writes
# contains secrets and goes only to the destination you name.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<EOF
usage: $0 /Volumes/YOUR_USB [--env <file>]

Settings come from the environment or from .env (see .env.example):

  COMPUTER_NAME        e.g. SAG-AIR12-LITE-101   (prompted if not set)
  ADMIN_PASSWORD       password for the local admin account   (required)
  TAILSCALE_AUTH_KEY   tagged, reusable, pre-approved         (required)
  ADMIN_USERNAME       default SAGAdmin
  TAILSCALE_TAGS       default tag:clinic-workstation
  TIMEZONE             default Pacific Standard Time
  WIPE=1               delete existing contents of the stick first

Wifi profiles: every .xml in ./wifi/ is copied and imported, so several
networks can be pre-seeded. Export each with key=clear, or it will not
import on another machine:

  netsh wlan export profile name="FireFlood" key=clear folder=C:\\Temp

The stick must be MS-DOS (FAT32) or ExFAT. Disk Utility defaults to APFS,
which Windows cannot read at all.
EOF
}

DEST=""; ENV_FILE=".env"
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) DEST="$1"; shift ;;
  esac
done
[ -n "$DEST" ] || { usage; exit 2; }
[ -d "$DEST" ] || { echo "destination '$DEST' is not a directory"; exit 1; }

# --- settings -----------------------------------------------------------------
# .env never overrides something already exported, so a one-off run can be
# steered from the command line without editing the file.
if [ -f "$ENV_FILE" ]; then
  echo "reading $ENV_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "${!key:-}" ] || export "$key=$val"
  done < "$ENV_FILE"
fi

# --- computer name: prompt when absent, and always validate -------------------
if [ -z "${COMPUTER_NAME:-}" ]; then
  printf 'computer name (e.g. SAG-AIR12-LITE-101): '
  read -r COMPUTER_NAME
fi
if ! printf '%s' "$COMPUTER_NAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' \
   || printf '%s' "$COMPUTER_NAME" | grep -qE -- '-$' \
   || printf '%s' "$COMPUTER_NAME" | grep -qE '^[0-9]+$'; then
  echo "ERROR: '$COMPUTER_NAME' is not a valid Windows hostname"
  echo "       1-63 chars, letters/digits/hyphen, not all digits, no trailing hyphen"
  exit 1
fi
if [ "${#COMPUTER_NAME}" -gt 15 ]; then
  echo "note: '$COMPUTER_NAME' is longer than 15 characters, so its NetBIOS name will"
  echo "      be truncated to '${COMPUTER_NAME:0:15}'. Fleet uses the full name."
fi

: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD in the environment or .env}"
: "${TAILSCALE_AUTH_KEY:?set TAILSCALE_AUTH_KEY in the environment or .env}"
ADMIN_USER="${ADMIN_USERNAME:-${ADMIN_USER:-SAGAdmin}}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-tag:clinic-workstation}"
TIMEZONE="${TIMEZONE:-Pacific Standard Time}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1}"

# --- destination sanity -------------------------------------------------------
# Windows cannot read APFS or HFS+ at all. A stick formatted with Disk Utility's
# default settings is APFS, which looks fine on the Mac and is completely
# invisible to Windows Setup - a failure with no error message anywhere.
# `|| true` matters: under `set -e` a failing diskutil would kill the script
# before the "could not determine" branch below could ever run.
FS="$(diskutil info "$DEST" 2>/dev/null | awk -F: '/File System Personality/ {gsub(/^ +/,"",$2); print $2}' || true)"
case "$FS" in
  *ExFAT*|*FAT32*|*MS-DOS*) echo "destination: $DEST ($FS)" ;;
  "")  echo "warning: could not determine the filesystem of '$DEST' - continuing" ;;
  *)   echo "ERROR: '$DEST' is formatted as $FS, which Windows cannot read."
       echo "       Reformat as MS-DOS (FAT32) or ExFAT in Disk Utility."
       exit 1 ;;
esac

if [ "${WIPE:-}" = "1" ]; then
  echo "wiping existing contents of $DEST"
  # Contents only. Formatting stays in Disk Utility so this script can never
  # target the wrong disk.
  find "$DEST" -mindepth 1 -maxdepth 1 ! -name '.Spotlight-V100' ! -name '.fseventsd' \
       ! -name '.Trashes' -exec rm -rf {} + 2>/dev/null || true
fi

fill() {
  sed -e "s|{{COMPUTER_NAME}}|$COMPUTER_NAME|g" \
      -e "s|{{ADMIN_USER}}|$ADMIN_USER|g" \
      -e "s|{{ADMIN_PASSWORD}}|$ADMIN_PASSWORD|g" \
      -e "s|{{TAILSCALE_AUTH_KEY}}|$TAILSCALE_AUTH_KEY|g" \
      -e "s|{{TAILSCALE_TAGS}}|$TAILSCALE_TAGS|g" \
      -e "s|{{TIMEZONE}}|$TIMEZONE|g" \
      -e "s|{{BOOTSTRAP_URL}}|$BOOTSTRAP_URL|g" \
      "$1" > "$2"
}

umask 077
mkdir -p "$DEST/fleet/wifi"
fill autounattend.template.xml "$DEST/Autounattend.xml"
fill setup.template.ps1        "$DEST/fleet/setup.ps1"

# --- wifi profiles ------------------------------------------------------------
# Generated from SSID + passphrase, because a Windows WLAN profile is just a
# documented XML format and exporting one from a live Windows box is a detour.
# macOS has no equivalent to export, so generating is the only option there.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

write_profile() {  # write_profile <ssid> <passphrase> <dest>
  local ssid pass dest
  ssid="$(xml_escape "$1")"; pass="$(xml_escape "$2")"; dest="$3"
  cat > "$dest" <<PROFILE
<?xml version="1.0" encoding="US-ASCII"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>${ssid}</name>
  <SSIDConfig>
    <SSID><name>${ssid}</name></SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>${pass}</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
PROFILE
}

WIFI_COUNT=0

# WIFI_1_SSID / WIFI_1_PASSWORD, WIFI_2_..., numbered so passphrases can contain
# any character without needing a delimiter.
for n in $(seq 1 9); do
  ssid_var="WIFI_${n}_SSID"; pass_var="WIFI_${n}_PASSWORD"
  ssid="${!ssid_var:-}"; pass="${!pass_var:-}"
  [ -n "$ssid" ] || continue
  if [ -z "$pass" ]; then echo "ERROR: $ssid_var is set but $pass_var is empty"; exit 1; fi
  write_profile "$ssid" "$pass" "$DEST/fleet/wifi/${n}-${ssid}.xml"
  echo "  wifi: $ssid (generated)"
  WIFI_COUNT=$((WIFI_COUNT + 1))
done

# Hand-supplied profiles remain supported for anything the generator cannot
# express - hidden SSIDs, enterprise auth, captive portals.
if compgen -G "wifi/*.xml" > /dev/null; then
  for f in wifi/*.xml; do
    if ! grep -qi "<keyMaterial>" "$f" || grep -qi "<protected>true</protected>" "$f"; then
      echo "WARNING: $(basename "$f") has no plaintext key - export it with key=clear,"
      echo "         an encrypted profile is bound to the machine that exported it"
    fi
    cp "$f" "$DEST/fleet/wifi/$(basename "$f")"
    echo "  wifi: $(basename "$f") (supplied)"
    WIFI_COUNT=$((WIFI_COUNT + 1))
  done
fi
[ "$WIFI_COUNT" -eq 0 ] && echo "  wifi: none (assuming wired)"

if grep -q '{{' "$DEST/Autounattend.xml" "$DEST/fleet/setup.ps1"; then
  echo "ERROR: unfilled placeholders remain:"
  grep -o '{{[A-Z_]*}}' "$DEST/Autounattend.xml" "$DEST/fleet/setup.ps1" | sort -u
  exit 1
fi

cat <<EOF

wrote to $DEST
  Autounattend.xml        computer name: $COMPUTER_NAME
  fleet/setup.ps1         first-logon script
  fleet/wifi/             $WIFI_COUNT profile(s)

This stick holds the local admin password, the Tailscale auth key and any wifi
keys in plaintext. Treat it as a credential: keep it with you, and rotate the
Tailscale key once you have finished provisioning.

Plug it in BEFORE the machine's first boot, then power on and walk away.
EOF
