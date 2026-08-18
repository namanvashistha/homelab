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
# Idempotent: the installer is skipped once the binary exists, but the drop-in
# and the unit state are reasserted every run.
install_periphery() {
    if ! command -v python3 &>/dev/null; then
        log "installing python3 (the periphery installer is a python script)"
        apt-get update -qq && apt-get install -y -qq python3
    fi

    local server_name
    server_name=$(sed -n 's/^KOMODO_SERVER_NAME=//p' "$ENV_FILE" | tail -1)
    server_name="${server_name:-Local}"

    # Re-run on a key too: the installer writes it into periphery.config.toml,
    # so pairing a box that already has the binary goes through here.
    if [ ! -x /usr/local/bin/periphery ] || [ -n "${PERIPHERY_ONBOARDING_KEY:-}" ]; then
        log "installing periphery (systemd)"
        # Core publishes 9120 on loopback for exactly this. Periphery dials
        # Core, so the Server in infra.toml carries no address.
        curl -fsSL "$PERIPHERY_SETUP_URL" | python3 - \
            --core-address "ws://127.0.0.1:9120" \
            --connect-as "$server_name" \
            ${PERIPHERY_ONBOARDING_KEY:+--onboarding-key "$PERIPHERY_ONBOARDING_KEY"} \
            ${KOMODO_PERIPHERY_VERSION:+--version "$KOMODO_PERIPHERY_VERSION"} \
            || fail "periphery install failed"
    elif ! grep -q '^onboarding_key' /etc/komodo/periphery.config.toml 2>/dev/null; then
        log "note: agent unpaired. Komodo -> Servers -> onboarding key, then"
        log "      PERIPHERY_ONBOARDING_KEY=O-... bash \$0"
    fi

    # stats/mem.rs subtracts the ZFS ARC from used memory and saturates at zero.
    # Inside an LXC that ARC is the Proxmox host's, so the graph pinned at
    # 0.00 GB. Hiding the file makes it read 0 and the subtraction a no-op.
    # Leading `-` so a non-ZFS host does not fail to start.
    mkdir -p /etc/systemd/system/periphery.service.d
    cat >/etc/systemd/system/periphery.service.d/override.conf <<'EOF'
[Service]
InaccessiblePaths=-/proc/spl
EOF

    systemctl daemon-reload
    systemctl enable --quiet periphery
    systemctl restart periphery
}

main() {
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
