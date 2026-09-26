#!/bin/sh
# Family Messenger (E2E) — create a Proxmox LXC and install the messenger in it.
#
#   curl -fsSL https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main/deploy/proxmox.sh | sh
#
# Runs on the Proxmox VE host, not inside a container. It creates an
# unprivileged Debian 13 container, then runs deploy/install.sh inside it in
# the `release` flavour: a prebuilt server, Caddy and coturn as systemd
# services, nothing compiled. That is why 1 vCPU and 1 GB are enough.
#
# Everything is asked with a sensible default and can be answered from the
# environment for an unattended run, e.g.
#
#   CTID=120 DOMAIN=chat.example.com EXTERNAL_IP=203.0.113.7 \
#     curl -fsSL https://raw.githubusercontent.com/.../deploy/proxmox.sh | sh
#
# Container variables: CTID, HOSTNAME, STORAGE, TEMPLATE_STORAGE, CORES,
# MEMORY, DISK, BRIDGE, NET (dhcp, or a CIDR such as 192.168.1.50/24),
# GATEWAY (static NET only), UNPRIVILEGED, START_ON_BOOT, TEMPLATE.
# Messenger variables, passed through to install.sh: DOMAIN (blank or "auto"
# uses the container's own address), EXTERNAL_IP, TURN_SECRET,
# MSGR_REGISTRATION (open|invite|closed), RELEASE.
set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main}"
WRAPPER=/usr/local/bin/family-messenger

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# True when a terminal can be opened (false under ssh without -t, cron, CI).
has_tty() { (exec 3</dev/tty) 2>/dev/null; }

# Reads an answer from the terminal even when the script itself is piped in.
ask() {
  prompt="$1"; default="$2"; answer=""
  if has_tty; then
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    read -r answer </dev/tty || answer=""
  fi
  if [ -n "$answer" ]; then printf '%s\n' "$answer"; else printf '%s\n' "$default"; fi
}

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox VE host, not inside a container"
command -v pveam >/dev/null 2>&1 || die "pveam not found: run this on the Proxmox VE host"

case "$(uname -m)" in
  x86_64|amd64) HOSTARCH=amd64 ;;
  aarch64|arm64) HOSTARCH=arm64 ;;
  *) die "unsupported host architecture $(uname -m)" ;;
esac

# First storage that can hold the named content type.
first_storage() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1; exit }'
}

# ---------------------------------------------------------------- settings

CTID="${CTID:-$(ask 'Container ID' "$(pvesh get /cluster/nextid 2>/dev/null || echo 120)")}"
pct status "$CTID" >/dev/null 2>&1 && die "container $CTID already exists; pick another CTID"

HOSTNAME="${HOSTNAME:-$(ask 'Hostname' family-messenger)}"

default_storage="$(first_storage rootdir)"
[ -n "$default_storage" ] || die "no active storage accepts containers (content type rootdir)"
STORAGE="${STORAGE:-$(ask 'Storage for the container' "$default_storage")}"

default_template_storage="$(first_storage vztmpl)"
[ -n "$default_template_storage" ] || die "no active storage accepts templates (content type vztmpl)"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$default_template_storage}"

CORES="${CORES:-$(ask 'CPU cores' 1)}"
MEMORY="${MEMORY:-$(ask 'Memory in MB' 1024)}"
DISK="${DISK:-$(ask 'Disk in GB' 8)}"
BRIDGE="${BRIDGE:-$(ask 'Network bridge' vmbr0)}"
NET="${NET:-$(ask 'IPv4 address (dhcp, or a CIDR such as 192.168.1.50/24)' dhcp)}"
GATEWAY="${GATEWAY:-}"
if [ "$NET" != "dhcp" ] && [ -z "$GATEWAY" ]; then
  GATEWAY="$(ask 'Gateway' "$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')")"
fi
UNPRIVILEGED="${UNPRIVILEGED:-1}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# Asked here rather than after the container exists, so the whole run is
# unattended once the questions are answered. "auto" is resolved to the
# container's own address as soon as it has one.
DOMAIN="${DOMAIN:-$(ask 'Domain name, or "auto" for the container IP (a name gets a Let'\''s Encrypt certificate)' auto)}"
EXTERNAL_IP="${EXTERNAL_IP:-}"
MSGR_REGISTRATION="${MSGR_REGISTRATION:-$(ask 'Registration (open/invite/closed)' invite)}"
RELEASE="${RELEASE:-}"

# ---------------------------------------------------------------- template

if [ -z "${TEMPLATE:-}" ]; then
  # An already-downloaded Debian 13 template beats a fresh download.
  TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null |
    awk -v a="$HOSTARCH" '$1 ~ ("debian-13-standard_.*_" a "\\.tar\\.(zst|gz|xz)$") { print $1; exit }')"
fi
if [ -z "$TEMPLATE" ]; then
  say "Refreshing the template catalogue"
  pveam update >/dev/null 2>&1 || warn "pveam update failed; using the cached catalogue"
  candidate="$(pveam available --section system 2>/dev/null |
    awk -v a="$HOSTARCH" '$2 ~ ("^debian-13-standard_.*_" a "\\.tar\\.(zst|gz|xz)$") { print $2 }' | sort -V | tail -n 1)"
  [ -n "$candidate" ] || die "no debian-13-standard template for $HOSTARCH in the catalogue"
  say "Downloading $candidate to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$candidate" >/dev/null || die "could not download $candidate"
  TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$candidate"
fi

# ---------------------------------------------------------------- container

if [ "$NET" = "dhcp" ]; then
  netconf="name=eth0,bridge=$BRIDGE,ip=dhcp"
else
  netconf="name=eth0,bridge=$BRIDGE,ip=$NET"
  [ -z "$GATEWAY" ] || netconf="$netconf,gw=$GATEWAY"
fi

say "Creating container $CTID ($HOSTNAME) on $STORAGE"
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap 512 \
  --rootfs "$STORAGE:$DISK" \
  --unprivileged "$UNPRIVILEGED" \
  --features nesting=1 \
  --net0 "$netconf" \
  --onboot "$START_ON_BOOT" \
  --start 1 >/dev/null || die "pct create failed"

cleanup_failed_container() {
  [ "${INSTALL_OK:-}" = 1 ] && return 0
  warn "leaving container $CTID in place for inspection; remove it with: pct destroy $CTID --force"
}
trap cleanup_failed_container EXIT

say "Waiting for the container to come up"
i=0
until pct exec "$CTID" -- test -d /proc/1 >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || die "container $CTID did not start"
  sleep 1
done

say "Waiting for the network"
i=0
until pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 90 ] || die "no network in container $CTID (bridge $BRIDGE, ip $NET)"
  sleep 1
done

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
[ -n "$CT_IP" ] || die "could not read the container's IPv4 address"
say "Container $CTID is up at $CT_IP"

case "$DOMAIN" in ""|auto) DOMAIN="$CT_IP" ;; esac
[ -n "$EXTERNAL_IP" ] || EXTERNAL_IP="$CT_IP"

# ---------------------------------------------------------------- install

say "Installing prerequisites"
pct exec "$CTID" -- sh -c 'export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8; apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null' ||
  die "could not install curl in container $CTID"

# A checkout next to this script installs its own installer, so a local change
# can be tried without pushing it first; otherwise the container downloads it.
# Guarded on $0 the way install.sh does: piped in through curl, $0 is "sh" and
# the current directory must not be mistaken for a checkout.
script_dir=""
case "$0" in
  */deploy/proxmox.sh|deploy/proxmox.sh)
    script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || script_dir=""
    ;;
esac
if [ -n "$script_dir" ] && [ -f "$script_dir/install.sh" ]; then
  say "Using the installer from $script_dir"
  pct push "$CTID" "$script_dir/install.sh" /root/install.sh --perms 755
else
  say "Downloading the installer"
  pct exec "$CTID" -- sh -c "curl -fsSL '$REPO_RAW/deploy/install.sh' -o /root/install.sh && chmod 755 /root/install.sh" ||
    die "could not download the installer into container $CTID"
fi

say "Installing Family Messenger (release flavour)"
log="$(mktemp)"
# pct exec hands over PATH=/sbin:/bin:/usr/sbin:/usr/bin, without /usr/local/bin.
# The installer puts its `family-messenger` wrapper there and calls it to mint
# the first invite code, so without this the install still succeeds but hands
# back no code. LC_ALL keeps apt's perl from warning about an unset locale.
if pct exec "$CTID" -- env \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LC_ALL=C.UTF-8 \
  INSTALL_MODE=release \
  DOMAIN="$DOMAIN" \
  EXTERNAL_IP="$EXTERNAL_IP" \
  MSGR_REGISTRATION="$MSGR_REGISTRATION" \
  ${TURN_SECRET:+TURN_SECRET="$TURN_SECRET"} \
  ${RELEASE:+RELEASE="$RELEASE"} \
  sh /root/install.sh 2>&1 | tee "$log"; then
  :
else
  rm -f "$log"
  die "the installer failed inside container $CTID; look at: pct enter $CTID, then journalctl -u family-messenger -n 50"
fi

invite="$(sed -n 's/.*Invite code: *\([^ ]*\).*/\1/p' "$log" | head -n 1)"
version="$(pct exec "$CTID" -- /opt/family-messenger-e2e/bin/server version 2>/dev/null || echo unknown)"
rm -f "$log"
# Re-running the installer over an existing install prints no code, and there
# is no point in sending someone to the wrapper for the very first account.
if [ -z "$invite" ] && [ "$MSGR_REGISTRATION" = invite ]; then
  invite="$(pct exec "$CTID" -- "$WRAPPER" invite -n 1 2>/dev/null | tail -n 1 || true)"
fi
INSTALL_OK=1

# ---------------------------------------------------------------- summary

printf '\n\033[1;32mFamily Messenger %s is running in container %s.\033[0m\n' "$version" "$CTID"
printf '  Open:            https://%s\n' "$DOMAIN"
[ -z "$invite" ] || printf '  Invite code:     %s   (the first account becomes the administrator)\n' "$invite"
# Spelled out in full: pct exec does not put /usr/local/bin on PATH, so the
# bare `family-messenger` these commands would otherwise use is not found.
printf '  More invites:    pct exec %s -- %s invite -n 3\n' "$CTID" "$WRAPPER"
printf '  Administrators:  pct exec %s -- %s admin list\n' "$CTID" "$WRAPPER"
printf '  Update:          pct exec %s -- %s update\n' "$CTID" "$WRAPPER"
printf '  Logs:            pct exec %s -- journalctl -u family-messenger -f\n' "$CTID"
printf '  Data:            /var/lib/family-messenger inside the container (back this up)\n'
printf '  Shell:           pct enter %s\n' "$CTID"
case "$DOMAIN" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*)
    printf '\n  Note: "%s" gets a certificate from the local CA, so browsers warn once and\n' "$DOMAIN"
    printf '        the Flutter app will not connect. Re-run the installer inside the container\n'
    printf '        with a real domain name once DNS points at it:\n'
    printf '          pct exec %s -- env DOMAIN=chat.example.com sh /root/install.sh\n' "$CTID" ;;
  *)
    printf '\n  Ports 80/tcp, 443/tcp+udp, 3478/tcp+udp and 49160-49200/udp must reach %s\n' "$CT_IP" ;;
esac
