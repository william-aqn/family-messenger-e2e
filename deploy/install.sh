#!/bin/sh
# Family Messenger (E2E) — one-line installer and updater for Linux hosts.
#
#   curl -fsSL https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main/deploy/install.sh | sudo sh
#
# Non-interactive: pass the answers through the environment, e.g.
#   DOMAIN=chat.example.com EXTERNAL_IP=203.0.113.10 curl -fsSL ... | sudo -E sh
#
# Optional variables: DOMAIN, EXTERNAL_IP, TURN_SECRET, MSGR_REGISTRATION
# (open|invite|closed), MSGR_IMAGE, INSTALL_DIR (default /opt/family-messenger-e2e),
# BRANCH (default main), REPO_URL.
set -eu

REPO_URL="${REPO_URL:-https://github.com/william-aqn/family-messenger-e2e.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/family-messenger-e2e}"
DEFAULT_IMAGE="ghcr.io/william-aqn/family-messenger-e2e:latest"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this installer supports Linux only"
[ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL <url> | sudo sh"

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "$@"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "$@"
  else
    die "unsupported distribution: please install $* manually and re-run"
  fi
}

command -v curl >/dev/null 2>&1 || { say "Installing curl"; pkg_install curl; }
command -v git >/dev/null 2>&1 || { say "Installing git"; pkg_install git; }
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing (install docker-compose-plugin)"
if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker >/dev/null 2>&1 || true; fi

if [ -d "$INSTALL_DIR/.git" ]; then
  say "Updating $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch -q origin "$BRANCH"
  git -C "$INSTALL_DIR" reset -q --hard "origin/$BRANCH"
else
  say "Cloning into $INSTALL_DIR"
  git clone -q --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR/deploy"

# Reads an answer from the terminal even when the script itself is piped in.
ask() {
  prompt="$1"; default="$2"; answer=""
  if [ -r /dev/tty ]; then
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    read -r answer </dev/tty || answer=""
  fi
  [ -n "$answer" ] && printf '%s\n' "$answer" || printf '%s\n' "$default"
}

if [ ! -f .env ]; then
  detected_ip="$(curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  DOMAIN="${DOMAIN:-$(ask 'Domain name (DNS must point to this machine; "localhost" for a LAN test)' "${detected_ip:-localhost}")}"
  EXTERNAL_IP="${EXTERNAL_IP:-$(ask 'Public IP of this machine (used for calls)' "${detected_ip:-127.0.0.1}")}"
  TURN_SECRET="${TURN_SECRET:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  MSGR_REGISTRATION="${MSGR_REGISTRATION:-invite}"
  MSGR_IMAGE="${MSGR_IMAGE:-$DEFAULT_IMAGE}"
  cat >.env <<EOF
DOMAIN=$DOMAIN
EXTERNAL_IP=$EXTERNAL_IP
TURN_SECRET=$TURN_SECRET
MSGR_REGISTRATION=$MSGR_REGISTRATION
MSGR_IMAGE=$MSGR_IMAGE
EOF
  chmod 600 .env
  say "Wrote $INSTALL_DIR/deploy/.env"
fi
DOMAIN="$(sed -n 's/^DOMAIN=//p' .env)"
MSGR_REGISTRATION="$(sed -n 's/^MSGR_REGISTRATION=//p' .env)"

say "Starting (pulls the prebuilt image, builds locally if it is unavailable)"
if docker compose pull -q server 2>/dev/null; then
  docker compose up -d --remove-orphans
else
  say "Prebuilt image not available, building locally (this takes a few minutes)"
  docker compose up -d --build --remove-orphans
fi

say "Waiting for the server"
i=0
until docker compose logs --no-log-prefix server 2>/dev/null | grep -q 'listening'; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || die "the server did not start; check: cd $INSTALL_DIR/deploy && docker compose logs server"
  sleep 1
done

invite=""
if [ "$MSGR_REGISTRATION" = "invite" ]; then
  invite="$(docker compose exec -T server /server invite -n 1 2>/dev/null | tail -n 1 || true)"
fi

printf '\n\033[1;32mFamily Messenger is running.\033[0m\n'
printf '  Open:            https://%s\n' "$DOMAIN"
[ -n "$invite" ] && printf '  Invite code:     %s   (the first account becomes the administrator)\n' "$invite"
printf '  More invites:    cd %s/deploy && docker compose exec server /server invite -n 3\n' "$INSTALL_DIR"
printf '  Logs:            cd %s/deploy && docker compose logs -f\n' "$INSTALL_DIR"
printf '  Update:          re-run this installer\n'
printf '  Firewall:        allow 80/tcp, 443/tcp+udp, 3478/tcp+udp and 49160-49200/udp\n'
[ "$DOMAIN" = "localhost" ] && printf '  Note: with DOMAIN=localhost the browser will warn about the local certificate.\n'
exit 0
