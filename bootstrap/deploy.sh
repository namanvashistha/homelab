#!/usr/bin/env bash
#
# Bootstrap this box: docker, the shared caddy network, this repo, the four
# services in bootstrap/docker-compose.yml, and Periphery as a systemd unit.
# Everything else on the host is deployed by Komodo — see ../README.md.
#
# This script replaced a version that cloned and `compose up`'d a list of app
# repos. That job is Komodo's now, which is why there is no REPOS array here
# and no per-app logic of any kind. Adding a service should never mean editing
# this file.
#
# Run on a fresh box:
#   curl -fsSL https://raw.githubusercontent.com/namanvashistha/homelab/main/bootstrap/deploy.sh | sudo bash
#
# Re-run it whenever bootstrap/docker-compose.yml changes. That is the one
# thing Komodo does not apply for you, and it cannot: Periphery would be
# restarting the Core it reports to, and killing its own compose command to do
# it. Everything else on this box — stacks, procedures, the server — is
# reconciled from komodo/syncs every ten minutes.
#
# Idempotent: `compose up -d` on an unchanged stack is a no-op, so running this
# when nothing changed costs nothing.

set -euo pipefail

REPO_URL="https://github.com/namanvashistha/homelab.git"
PERIPHERY_SETUP_URL="https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py"

# Even under sudo, the checkout belongs to the invoking user's home.
if [ -n "${SUDO_USER:-}" ]; then
    TARGET_HOME=$(eval echo "~${SUDO_USER}")
else
    TARGET_HOME="$HOME"
fi

BASE_DIR="${HOMELAB_DIR:-$TARGET_HOME/homelab}"
COMPOSE_FILE="$BASE_DIR/bootstrap/docker-compose.yml"
ENV_FILE="$BASE_DIR/bootstrap/.env"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        return
    fi
    log "installing docker"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    command -v docker &>/dev/null || fail "docker install failed"
}

sync_repo() {
    if [ ! -d "$BASE_DIR/.git" ]; then
        log "cloning $REPO_URL -> $BASE_DIR"
        git clone --quiet "$REPO_URL" "$BASE_DIR"
        return
    fi
    log "updating $BASE_DIR"
    git -C "$BASE_DIR" pull --quiet --ff-only \
        || fail "pull failed — resolve by hand, this script will not force it"
}

# The caddy network and volume are created here rather than by compose because
# compose will not adopt resources it did not create: pointing a compose file at
# an existing network with `name:` fails with "has incorrect label
# com.docker.compose.network". Making them compose-owned would mean tearing down
# every container on the box once. Both commands are idempotent.
ensure_shared_resources() {
    docker network inspect caddy &>/dev/null || {
        log "creating caddy network"
        docker network create caddy >/dev/null
    }
    docker volume inspect caddy_data &>/dev/null || {
        log "creating caddy_data volume"
        docker volume create caddy_data >/dev/null
    }
    # Komodo Core writes dated database dumps here.
    mkdir -p /etc/komodo/backups
}

# Periphery runs on the host, not in a container. Two reasons, both measured:
# in a container lxcfs answers /proc/meminfo for the container's own cgroup, so
# the server's memory reads ~10 MiB; and the Komodo terminal lands in the
# container rather than on the box. See komodo/syncs/infra.toml.
#
# Upstream installs this with scripts/setup-periphery.py. Inlined here instead:
# it is four curls and a heredoc, it was the only thing on this box that needed
# python, and its write_config() early-returns on an existing file — so passing
# an onboarding key to an already-installed agent silently did nothing.
install_periphery() {
    local version arch tmp
    version="${KOMODO_PERIPHERY_VERSION:-}"
    if [ -z "$version" ]; then
        version=$(curl -fsSL https://api.github.com/repos/moghtech/komodo/releases/latest \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
        [ -n "$version" ] || fail "could not resolve the latest periphery version"
    fi

    case "$(uname -m)" in
        aarch64|arm64) arch=aarch64 ;;
        *)             arch=x86_64 ;;
    esac

    # Downloaded every run, so `deploy.sh` is also how the agent gets updated —
    # Core is pinned by KOMODO_IMAGE_TAG and a drift raises ServerVersionMismatch.
    # Staged in a temp file so a failed download cannot leave a truncated binary.
    log "installing periphery $version ($arch)"
    tmp=$(mktemp)
    curl -fsSL "https://github.com/moghtech/komodo/releases/download/$version/periphery-$arch" \
        -o "$tmp" || fail "periphery $version download failed — check the tag exists"
    chmod +x "$tmp"
    mv "$tmp" /usr/local/bin/periphery

    # Written once. Everything else takes the binary's defaults; these three
    # are the ones that are wrong by default here.
    mkdir -p /etc/komodo
    if [ ! -f /etc/komodo/periphery.config.toml ]; then
        local server_name
        server_name=$(sed -n 's/^KOMODO_SERVER_NAME=//p' "$ENV_FILE" | tail -1)
        cat >/etc/komodo/periphery.config.toml <<EOF
# Written by bootstrap/deploy.sh. Periphery dials Core, which is why the Server
# in komodo/syncs/infra.toml carries no address — and why Core publishes 9120
# on loopback.
root_directory = "/etc/komodo"
core_address = "ws://127.0.0.1:9120"
connect_as = "${server_name:-Local}"
EOF
    fi

    # Pairing. Core learns this agent's public key from the onboarding key and
    # stores it in mongo, so this is needed once per box, not once per run.
    if [ -n "${PERIPHERY_ONBOARDING_KEY:-}" ]; then
        sed -i '/^onboarding_key = /d' /etc/komodo/periphery.config.toml
        echo "onboarding_key = \"$PERIPHERY_ONBOARDING_KEY\"" \
            >>/etc/komodo/periphery.config.toml
    elif ! grep -q '^onboarding_key = ' /etc/komodo/periphery.config.toml; then
        log "note: agent unpaired. Komodo -> Servers -> onboarding key, then"
        log "      bash $BASE_DIR/bootstrap/deploy.sh --onboarding-key O-..."
    fi

    # WantedBy=default.target matches upstream's unit.
    cat >/etc/systemd/system/periphery.service <<'EOF'
[Unit]
Description=Agent to connect with Komodo Core

[Service]
Environment="HOME=/root"
ExecStart=/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml
Restart=on-failure
TimeoutStartSec=0
# stats/mem.rs subtracts the ZFS ARC from used memory and saturates at zero.
# Inside an LXC that ARC is the Proxmox host's, so the graph pinned at 0.00 GB.
# Hiding the file makes the read fail and the subtraction a no-op. Leading `-`
# so a host without ZFS still starts.
InaccessiblePaths=-/proc/spl

[Install]
WantedBy=default.target
EOF

    systemctl daemon-reload
    systemctl enable --quiet periphery
    systemctl restart periphery
}

# --onboarding-key rather than only the env var: the documented install is
# `curl ... | sudo bash`, and sudo's env_reset drops the variable on the way
# through. A flag survives the pipe — pass it as `| sudo bash -s -- -k O-...`.
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --onboarding-key|-k)
                [ $# -ge 2 ] || fail "$1 needs a value"
                PERIPHERY_ONBOARDING_KEY="$2"
                shift 2
                ;;
            *) fail "unknown argument: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"

    [ "$(id -u)" -eq 0 ] || fail "run as root (docker install + /etc/komodo)"

    install_docker
    sync_repo
    ensure_shared_resources

    # Secrets cannot be automated. Fail loudly rather than starting a Komodo
    # with a blank admin password — every var in the example is `:?` required
    # in the compose file, so compose would refuse anyway, just less clearly.
    [ -f "$ENV_FILE" ] || fail "missing $ENV_FILE — copy bootstrap/.env.example and fill it in"

    log "bringing up the bootstrap stack"
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans

    # After compose, so Core is listening on 127.0.0.1:9120 when Periphery dials.
    install_periphery

    if ! systemctl is-active --quiet periphery; then
        log "WARNING: periphery is not running — journalctl -u periphery"
    fi

    log "done. Komodo deploys everything else — see README.md"
}

main "$@"
