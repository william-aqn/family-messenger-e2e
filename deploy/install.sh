#!/bin/sh
# Family Messenger (E2E) — one-line installer and updater for Linux hosts.
#
#   curl -fsSL https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main/deploy/install.sh | sudo sh
#
# The first run asks which flavour to install (remembered in deploy/.env):
#   release  the prebuilt server from GitHub Releases (default): one static
#            binary with the web client inside, Caddy as a static binary and
#            coturn from the distribution, all as systemd services. Nothing is
#            compiled, so a 1 vCPU / 512 MB box is enough
#   docker   server, Caddy and coturn in containers; Docker is installed if missing
#   source   like release, but the server is compiled here from the checkout
#            (Go and Node are downloaded into INSTALL_DIR/toolchain when the
#            system has none; needs about 2 GB of memory for the build)
#
# Re-running the installer (or `family-messenger update`) updates the flavour
# in place: the newest release, the newest image, or a fresh build.
#
# Non-interactive: pass the answers through the environment, e.g.
#   INSTALL_MODE=release DOMAIN=chat.example.com curl -fsSL ... | sudo -E sh
#
# Optional variables: INSTALL_MODE (release|docker|source), RELEASE (a tag such
# as v0.2.0 instead of the newest release), DOMAIN, EXTERNAL_IP, TURN_SECRET,
# MSGR_REGISTRATION (open|invite|closed), MSGR_IMAGE (docker only),
# MSGR_BINARY_URL (release only: download this binary instead), INSTALL_DIR
# (default /opt/family-messenger-e2e), BRANCH (default main), REPO_URL,
# GITHUB_REPO (owner/name for releases). Running `sh deploy/install.sh` inside
# a checkout installs that checkout as it is (no clone, no update).
set -eu

REPO_URL="${REPO_URL:-https://github.com/william-aqn/family-messenger-e2e.git}"
GITHUB_REPO="${GITHUB_REPO:-william-aqn/family-messenger-e2e}"
BRANCH="${BRANCH:-main}"
RELEASE="${RELEASE:-}"
INSTALL_DIR_GIVEN="${INSTALL_DIR:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/family-messenger-e2e}"
DEFAULT_IMAGE="ghcr.io/william-aqn/family-messenger-e2e:latest"
SERVICE_USER="family-messenger"
DATA_DIR="/var/lib/family-messenger"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
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

command -v curl >/dev/null 2>&1 || { say "Installing curl"; pkg_install curl ca-certificates; }

# ---------------------------------------------------------------- flavour

# `sh deploy/install.sh` inside a checkout installs that checkout.
LOCAL_CHECKOUT=""
case "$0" in
  *deploy/install.sh)
    candidate="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)"
    if [ -n "$candidate" ] && [ -f "$candidate/go.mod" ]; then LOCAL_CHECKOUT="$candidate"; fi
    ;;
esac
if [ -n "$LOCAL_CHECKOUT" ] && [ -z "$INSTALL_DIR_GIVEN" ]; then INSTALL_DIR="$LOCAL_CHECKOUT"; fi
mkdir -p "$INSTALL_DIR/deploy"
ENV_FILE="$INSTALL_DIR/deploy/.env"

INSTALL_MODE="${INSTALL_MODE:-}"
if [ -z "$INSTALL_MODE" ] && [ -f "$ENV_FILE" ]; then
  INSTALL_MODE="$(sed -n 's/^INSTALL_MODE=//p' "$ENV_FILE")"
  # installs made before the flavours existed
  [ -n "$INSTALL_MODE" ] || INSTALL_MODE=docker
fi
if [ -z "$INSTALL_MODE" ]; then
  if has_tty; then
    printf '\nHow should Family Messenger run?\n' >/dev/tty
    printf '  release  prebuilt server from GitHub Releases as systemd services (recommended, no Docker, nothing to compile)\n' >/dev/tty
    printf '  docker   everything in containers (Docker is installed if missing)\n' >/dev/tty
    printf '  source   systemd services with the server compiled here from the source checkout\n' >/dev/tty
  fi
  INSTALL_MODE="$(ask 'Installation type (release/docker/source)' release)"
fi
case "$INSTALL_MODE" in
  native) INSTALL_MODE=source ;; # the old name
  release|docker|source) ;;
  *) die "INSTALL_MODE must be release, docker or source (got '$INSTALL_MODE')" ;;
esac

# ---------------------------------------------------------------- source tree

# The docker and source flavours need the checkout (compose files, sources);
# the release flavour only needs this script.
if [ "$INSTALL_MODE" != "release" ]; then
  if [ -n "$LOCAL_CHECKOUT" ] && [ "$INSTALL_DIR" = "$LOCAL_CHECKOUT" ]; then
    say "Installing from the checkout at $INSTALL_DIR"
  else
    command -v git >/dev/null 2>&1 || { say "Installing git"; pkg_install git; }
    if [ -d "$INSTALL_DIR/.git" ]; then
      say "Updating $INSTALL_DIR"
      if git -C "$INSTALL_DIR" fetch -q origin "$BRANCH" && git -C "$INSTALL_DIR" merge -q --ff-only FETCH_HEAD; then
        :
      else
        warn "could not fast-forward $INSTALL_DIR to origin/$BRANCH; keeping the local version"
      fi
    else
      say "Cloning into $INSTALL_DIR"
      rm -rf "$INSTALL_DIR/deploy/.clone" 2>/dev/null || true
      git clone -q --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR/deploy/.clone"
      # keep the .env written by an earlier release install
      cp -a "$INSTALL_DIR/deploy/.clone/." "$INSTALL_DIR/"
      rm -rf "$INSTALL_DIR/deploy/.clone"
    fi
  fi
fi
cd "$INSTALL_DIR/deploy"

# ---------------------------------------------------------------- settings

if [ ! -f .env ]; then
  detected_ip="$(curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  DOMAIN="${DOMAIN:-$(ask 'Domain name (DNS must point to this machine; "localhost" for a LAN test)' "${detected_ip:-localhost}")}"
  EXTERNAL_IP="${EXTERNAL_IP:-$(ask 'Public IP of this machine (used for calls)' "${detected_ip:-127.0.0.1}")}"
  TURN_SECRET="${TURN_SECRET:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  MSGR_REGISTRATION="${MSGR_REGISTRATION:-invite}"
  MSGR_IMAGE="${MSGR_IMAGE:-$DEFAULT_IMAGE}"
  cat >.env <<EOF
INSTALL_MODE=$INSTALL_MODE
DOMAIN=$DOMAIN
EXTERNAL_IP=$EXTERNAL_IP
TURN_SECRET=$TURN_SECRET
MSGR_REGISTRATION=$MSGR_REGISTRATION
MSGR_IMAGE=$MSGR_IMAGE
EOF
  chmod 600 .env
  say "Wrote $INSTALL_DIR/deploy/.env"
else
  sed -i 's/^INSTALL_MODE=native$/INSTALL_MODE=source/' .env # the old name of the source flavour
  if ! grep -q '^INSTALL_MODE=' .env; then
    printf 'INSTALL_MODE=%s\n' "$INSTALL_MODE" >>.env
  elif [ "$(sed -n 's/^INSTALL_MODE=//p' .env)" != "$INSTALL_MODE" ]; then
    warn "switching the installation type to $INSTALL_MODE; stop the previous one first if it is still running"
    sed -i "s/^INSTALL_MODE=.*/INSTALL_MODE=$INSTALL_MODE/" .env
  fi
fi
DOMAIN="$(sed -n 's/^DOMAIN=//p' .env)"
EXTERNAL_IP="$(sed -n 's/^EXTERNAL_IP=//p' .env)"
TURN_SECRET="$(sed -n 's/^TURN_SECRET=//p' .env)"
MSGR_REGISTRATION="$(sed -n 's/^MSGR_REGISTRATION=//p' .env)"

print_footer() {
  printf '  Update:          family-messenger update   (or re-run this installer)\n'
  printf '  Firewall:        allow 80/tcp, 443/tcp+udp, 3478/tcp+udp and 49160-49200/udp\n'
  case "$DOMAIN" in
    localhost|*.local|*.lan|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
      printf '  Note: "%s" gets a certificate from the local CA; browsers warn once, and the\n' "$DOMAIN"
      printf '        Flutter app needs a real domain name with a public certificate.\n' ;;
  esac
}

# ---------------------------------------------------------------- docker

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing (install docker-compose-plugin)"
  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker >/dev/null 2>&1 || true; fi

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
  write_wrapper docker

  printf '\n\033[1;32mFamily Messenger is running (Docker).\033[0m\n'
  printf '  Open:            https://%s\n' "$DOMAIN"
  [ -z "$invite" ] || printf '  Invite code:     %s   (the first account becomes the administrator)\n' "$invite"
  printf '  More invites:    cd %s/deploy && docker compose exec server /server invite -n 3\n' "$INSTALL_DIR"
  printf '  Logs:            cd %s/deploy && docker compose logs -f\n' "$INSTALL_DIR"
  print_footer
}

# ---------------------------------------------------------------- release download

# Newest release tag from GitHub (empty when the API is unreachable or nothing was published).
latest_release_tag() {
  curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1
}

download_release() {
  installed="$("$BIN_DIR/server" version 2>/dev/null || true)"
  if [ -n "${MSGR_BINARY_URL:-}" ]; then
    say "Downloading the server binary from $MSGR_BINARY_URL"
    curl -fL --retry 3 -o "$BIN_DIR/server.new" "$MSGR_BINARY_URL"
  else
    tag="$RELEASE"
    if [ -z "$tag" ]; then
      tag="$(latest_release_tag)"
      [ -n "$tag" ] || die "no published release found for $GITHUB_REPO (or GitHub is unreachable); publish one with the release workflow, or use INSTALL_MODE=source or docker"
    fi
    if [ -n "$installed" ] && [ "$installed" = "$tag" ]; then
      say "Server $tag is already installed"
      return 0
    fi
    base="https://github.com/$GITHUB_REPO/releases/download/$tag"
    say "Downloading server $tag (server-linux-$GOARCH)"
    curl -fL --retry 3 -o "$BIN_DIR/server.new" "$base/server-linux-$GOARCH" || die "could not download $base/server-linux-$GOARCH"
    if curl -fsL -o "$BIN_DIR/sha256sums.txt" "$base/sha256sums.txt" 2>/dev/null; then
      expected="$(grep " server-linux-$GOARCH\$" "$BIN_DIR/sha256sums.txt" | awk '{print $1}')"
      actual="$(sha256sum "$BIN_DIR/server.new" | awk '{print $1}')"
      if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
        rm -f "$BIN_DIR/server.new"
        die "checksum mismatch for server-linux-$GOARCH (expected $expected, got $actual)"
      fi
      say "Checksum verified"
    else
      warn "no sha256sums.txt in the release; the download was not verified"
    fi
  fi
  chmod 755 "$BIN_DIR/server.new"
  "$BIN_DIR/server.new" version >/dev/null 2>&1 || die "the downloaded server binary does not run on this machine"
  mv -f "$BIN_DIR/server.new" "$BIN_DIR/server"
}

# ---------------------------------------------------------------- source build

# $1 >= $2 for dotted version numbers.
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }
go_version_of() { "$1" version 2>/dev/null | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p'; }

ensure_go() {
  want="$(sed -n 's/^go  *\([0-9][0-9.]*\).*/\1/p' "$INSTALL_DIR/go.mod")"
  case "$want" in *.*.*) ;; *) want="$want.0" ;; esac
  for candidate in "$(command -v go 2>/dev/null || true)" "$TOOLCHAIN/go/bin/go"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      have="$(go_version_of "$candidate")"
      if [ -n "$have" ] && version_ge "$have" "$want"; then GO="$candidate"; return 0; fi
    fi
  done
  say "Downloading Go $want"
  rm -rf "$TOOLCHAIN/go"
  curl -fsSL "https://go.dev/dl/go$want.linux-$GOARCH.tar.gz" | tar -xz -C "$TOOLCHAIN"
  GO="$TOOLCHAIN/go/bin/go"
}

ensure_node() {
  for candidate in "$(command -v node 2>/dev/null || true)" "$TOOLCHAIN/node/bin/node"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      have="$("$candidate" --version 2>/dev/null | tr -d v)"
      if [ -n "$have" ] && version_ge "$have" "22.0.0"; then NODE_BIN="$(dirname "$candidate")"; return 0; fi
    fi
  done
  say "Downloading Node.js 26"
  file="$(curl -fsSL https://nodejs.org/dist/latest-v26.x/ 2>/dev/null | grep -o "node-v26\.[0-9]*\.[0-9]*-linux-$NODEARCH\.tar\.gz" | head -n 1 || true)"
  [ -n "$file" ] || file="node-v26.8.2-linux-$NODEARCH.tar.gz"
  ver="${file#node-}"; ver="${ver%%-*}"
  rm -rf "$TOOLCHAIN/node"
  curl -fsSL "https://nodejs.org/dist/$ver/$file" | tar -xz -C "$TOOLCHAIN"
  mv "$TOOLCHAIN/${file%.tar.gz}" "$TOOLCHAIN/node"
  NODE_BIN="$TOOLCHAIN/node/bin"
}

# Compiling the server wants about 2 GB; small machines get a temporary swap file.
SWAPFILE=""
add_build_swap() {
  avail="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
  swapfree="$(awk '/SwapFree/ {print int($2/1024)}' /proc/meminfo)"
  [ $((avail + swapfree)) -lt 2500 ] || return 0
  say "Only ${avail} MB of memory available: adding a temporary 2 GB swap file for the build"
  SWAPFILE="/family-messenger-build.swap"
  rm -f "$SWAPFILE"
  if { fallocate -l 2G "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none; } \
     && chmod 600 "$SWAPFILE" && mkswap -q "$SWAPFILE" && swapon "$SWAPFILE"; then
    :
  else
    warn "could not enable the swap file; the build may run out of memory"
    rm -f "$SWAPFILE"; SWAPFILE=""
  fi
}
remove_build_swap() {
  if [ -n "$SWAPFILE" ]; then swapoff "$SWAPFILE" 2>/dev/null || true; rm -f "$SWAPFILE"; SWAPFILE=""; fi
}
trap remove_build_swap EXIT

build_server() {
  version="$(git -C "$INSTALL_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
  # A re-run that only changed .env must not spend minutes recompiling.
  case "$version" in
    dev|*-dirty) ;;
    *)
      if [ -x "$BIN_DIR/server" ] && [ "$(cat "$BIN_DIR/server.version" 2>/dev/null)" = "$version" ]; then
        say "Server $version is already built (delete $BIN_DIR/server.version to rebuild)"
        return 0
      fi ;;
  esac
  mkdir -p "$TOOLCHAIN"
  ensure_go
  ensure_node
  export PATH="$NODE_BIN:$PATH"
  export GOPATH="$TOOLCHAIN/gopath" GOCACHE="$TOOLCHAIN/gocache" GOFLAGS="-buildvcs=false" GOTOOLCHAIN=local CGO_ENABLED=0
  add_build_swap
  say "Building the web client (Node $(node --version))"
  (cd "$INSTALL_DIR/web" && npm ci --no-audit --no-fund --loglevel=error && APP_VERSION="$version" npm run build --silent)
  find "$INSTALL_DIR/internal/webui/dist" -mindepth 1 ! -name .keep -exec rm -rf {} + 2>/dev/null || true
  cp -R "$INSTALL_DIR/web/dist/." "$INSTALL_DIR/internal/webui/dist/"
  say "Building the server $version with $("$GO" version | cut -d' ' -f3) (several minutes on a small machine)"
  (cd "$INSTALL_DIR" && "$GO" build -trimpath -ldflags "-s -w -X github.com/william-aqn/family-messenger-e2e/internal/api.Version=$version" -o "$BIN_DIR/server.new" ./cmd/server)
  mv -f "$BIN_DIR/server.new" "$BIN_DIR/server"
  printf '%s\n' "$version" >"$BIN_DIR/server.version"
  remove_build_swap
}

# ---------------------------------------------------------------- systemd services

install_caddy() {
  if [ -x "$BIN_DIR/caddy" ]; then return 0; fi
  say "Downloading Caddy"
  if ! curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$GOARCH" -o "$BIN_DIR/caddy.new"; then
    tag="$(curl -fsSI https://github.com/caddyserver/caddy/releases/latest | sed -n 's|^[Ll]ocation:.*/tag/v\([0-9.]*\).*|\1|p' | tr -d '\r')"
    [ -n "$tag" ] || die "could not download Caddy"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v$tag/caddy_${tag}_linux_$GOARCH.tar.gz" | tar -xz -C "$tmp" caddy
    mv "$tmp/caddy" "$BIN_DIR/caddy.new"
    rm -rf "$tmp"
  fi
  chmod 755 "$BIN_DIR/caddy.new"
  "$BIN_DIR/caddy.new" version >/dev/null || die "the downloaded Caddy binary does not run"
  mv -f "$BIN_DIR/caddy.new" "$BIN_DIR/caddy"
}

write_native_config() {
  tls=""
  case "$DOMAIN" in
    localhost|*.local|*.lan|[0-9]*.[0-9]*.[0-9]*.[0-9]*) tls="tls internal" ;;
  esac
  cat >Caddyfile.native <<EOF
# Generated by install.sh from .env; re-run the installer after editing .env.
$DOMAIN {
	$tls
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
EOF
  # Fully expanded environment for the systemd unit (systemd does not expand \${VAR}).
  cat >server.env <<EOF
MSGR_ADDR=127.0.0.1:8080
MSGR_DATA_DIR=$DATA_DIR
MSGR_PUBLIC_URL=https://$DOMAIN
MSGR_REGISTRATION=$MSGR_REGISTRATION
MSGR_TURN_SECRET=$TURN_SECRET
MSGR_TURN_URLS=turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp
MSGR_STUN_URLS=stun:$DOMAIN:3478
MSGR_TURN_TTL=1h
EOF
  chown "root:$SERVICE_USER" server.env
  chmod 640 server.env

  if [ -f /etc/turnserver.conf ] && ! grep -q 'Family Messenger' /etc/turnserver.conf; then
    cp /etc/turnserver.conf /etc/turnserver.conf.orig
  fi
  cat >/etc/turnserver.conf <<EOF
# Managed by the Family Messenger installer; edits are overwritten on update.
listening-port=3478
realm=$DOMAIN
use-auth-secret
static-auth-secret=$TURN_SECRET
external-ip=$EXTERNAL_IP
min-port=49160
max-port=49200
fingerprint
no-multicast-peers
no-tlsv1
no-tlsv1_1
no-cli
syslog
EOF
  turn_group=""
  for g in turnserver coturn turn; do
    if getent group "$g" >/dev/null 2>&1; then turn_group="$g"; break; fi
  done
  if [ -n "$turn_group" ]; then chown "root:$turn_group" /etc/turnserver.conf; chmod 640 /etc/turnserver.conf; else chmod 644 /etc/turnserver.conf; fi
  if [ -f /etc/default/coturn ]; then sed -i 's/^#*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn; fi
}

write_units() {
  cat >/etc/systemd/system/family-messenger.service <<EOF
[Unit]
Description=Family Messenger server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$INSTALL_DIR/deploy/server.env
ExecStart=$BIN_DIR/server
WorkingDirectory=$DATA_DIR
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/family-messenger-caddy.service <<EOF
[Unit]
Description=Family Messenger reverse proxy (Caddy)
After=network-online.target family-messenger.service
Wants=network-online.target

[Service]
Type=notify
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=XDG_DATA_HOME=$DATA_DIR/caddy XDG_CONFIG_HOME=$DATA_DIR/caddy HOME=$DATA_DIR/caddy
ExecStart=$BIN_DIR/caddy run --config $INSTALL_DIR/deploy/Caddyfile.native --adapter caddyfile
ExecReload=$BIN_DIR/caddy reload --config $INSTALL_DIR/deploy/Caddyfile.native --adapter caddyfile --force
Restart=on-failure
RestartSec=3
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR/caddy

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# `family-messenger invite -n 3`, `family-messenger admin list`, `family-messenger
# version`: the server's subcommands as the service user with its environment;
# `family-messenger update`: the newest installer, re-run for this flavour.
write_wrapper() {
  flavour="$1"
  # The release flavour has no checkout, so the last downloaded installer is
  # kept as the offline fallback (a checkout carries its own copy under git).
  keep_copy=":"
  [ "$INSTALL_MODE" != release ] || keep_copy="cp -f \"\$tmp\" \"$INSTALL_DIR/deploy/install.sh\" 2>/dev/null || true"
  cat >/usr/local/bin/family-messenger <<EOF
#!/bin/sh
[ "\$(id -u)" -eq 0 ] || { echo "run as root: sudo family-messenger ..." >&2; exit 1; }
case "\${1:-}" in
  update)
    shift
    tmp="\$(mktemp)"
    if curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/deploy/install.sh" -o "\$tmp" 2>/dev/null; then
      $keep_copy
      INSTALL_DIR="$INSTALL_DIR" sh "\$tmp" "\$@"; rc=\$?
      rm -f "\$tmp"; exit \$rc
    fi
    rm -f "\$tmp"
    [ -f "$INSTALL_DIR/deploy/install.sh" ] || { echo "could not download the installer and there is no local copy" >&2; exit 1; }
    INSTALL_DIR="$INSTALL_DIR" exec sh "$INSTALL_DIR/deploy/install.sh" "\$@" ;;
esac
EOF
  if [ "$flavour" = docker ]; then
    cat >>/usr/local/bin/family-messenger <<EOF
cd "$INSTALL_DIR/deploy" && exec docker compose exec -T server /server "\$@"
EOF
  else
    cat >>/usr/local/bin/family-messenger <<EOF
exec runuser -u $SERVICE_USER -- /bin/sh -c 'set -a; . "$INSTALL_DIR/deploy/server.env"; set +a; exec "$BIN_DIR/server" "\$@"' sh "\$@"
EOF
  fi
  chmod 755 /usr/local/bin/family-messenger
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    say "Opening the ports in ufw"
    for p in 80/tcp 443/tcp 443/udp 3478/tcp 3478/udp 49160:49200/udp; do ufw allow "$p" >/dev/null; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    say "Opening the ports in firewalld"
    for p in 80/tcp 443/tcp 443/udp 3478/tcp 3478/udp 49160-49200/udp; do firewall-cmd -q --permanent --add-port="$p"; done
    firewall-cmd -q --reload
  fi
}

start_native_services() {
  if ! systemctl is-active -q family-messenger-caddy; then
    for port in 80 443; do
      if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
        die "port $port is already in use ($(ss -ltnpH "sport = :$port" | head -n 1)); stop that service first"
      fi
    done
  fi
  coturn_unit=""
  if systemctl cat coturn.service >/dev/null 2>&1; then coturn_unit=coturn
  elif systemctl cat turnserver.service >/dev/null 2>&1; then coturn_unit=turnserver
  fi
  systemctl enable -q family-messenger family-messenger-caddy
  systemctl restart family-messenger || die "the server did not start; check: journalctl -u family-messenger -n 50"
  systemctl restart family-messenger-caddy || die "Caddy did not start; check: journalctl -u family-messenger-caddy -n 50"
  if [ -n "$coturn_unit" ]; then
    systemctl enable -q "$coturn_unit" 2>/dev/null || true
    systemctl restart "$coturn_unit" || warn "coturn did not start (journalctl -u $coturn_unit); calls will only work without a relay"
  else
    warn "no coturn service found; calls will only work without a relay"
  fi
  say "Waiting for the server"
  i=0
  until curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "the server did not start; check: journalctl -u family-messenger -n 50"
    sleep 1
  done
}

install_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "the $INSTALL_MODE installation needs systemd; use INSTALL_MODE=docker"
  case "$(uname -m)" in
    x86_64|amd64) GOARCH=amd64; NODEARCH=x64 ;;
    aarch64|arm64) GOARCH=arm64; NODEARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m); use INSTALL_MODE=docker" ;;
  esac
  BIN_DIR="$INSTALL_DIR/bin"
  TOOLCHAIN="$INSTALL_DIR/toolchain"
  mkdir -p "$BIN_DIR" "$DATA_DIR/caddy"

  say "Installing packages (ca-certificates, coturn)"
  pkg_install ca-certificates coturn || die "could not install coturn (on RHEL-like systems enable EPEL first)"

  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    nologin="$(command -v nologin 2>/dev/null || echo /bin/false)"
    useradd --system --home-dir "$DATA_DIR" --no-create-home --shell "$nologin" "$SERVICE_USER"
  fi
  chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$DATA_DIR/caddy"
  chmod 750 "$DATA_DIR"

  if [ "$INSTALL_MODE" = "release" ]; then
    download_release
  else
    build_server
  fi
  install_caddy
  write_native_config
  write_units
  write_wrapper systemd
  open_firewall
  start_native_services

  invite=""
  if [ "$MSGR_REGISTRATION" = "invite" ]; then
    invite="$(family-messenger invite -n 1 2>/dev/null | tail -n 1 || true)"
  fi
  installed="$("$BIN_DIR/server" version 2>/dev/null || echo unknown)"

  printf '\n\033[1;32mFamily Messenger %s is running (%s).\033[0m\n' "$installed" "$INSTALL_MODE"
  printf '  Open:            https://%s\n' "$DOMAIN"
  [ -z "$invite" ] || printf '  Invite code:     %s   (the first account becomes the administrator)\n' "$invite"
  printf '  More invites:    family-messenger invite -n 3\n'
  printf '  Administrators:  family-messenger admin list | grant <user> | revoke <user>\n'
  printf '  Logs:            journalctl -u family-messenger -f   (proxy: -u family-messenger-caddy, TURN: -u %s)\n' "${coturn_unit:-coturn}"
  printf '  Services:        systemctl status family-messenger family-messenger-caddy %s\n' "${coturn_unit:-coturn}"
  printf '  Data:            %s (back this directory up)\n' "$DATA_DIR"
  printf '  Config:          %s/deploy/.env (re-run the installer after changes)\n' "$INSTALL_DIR"
  print_footer
}

if [ "$INSTALL_MODE" = "docker" ]; then install_docker; else install_systemd; fi
exit 0
