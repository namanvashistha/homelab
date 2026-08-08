#!/usr/bin/env bash
#
# Bootstrap this box: docker, the shared caddy network, this repo, and the five
# services in bootstrap/docker-compose.yml. Everything else on the host is
# deployed by Komodo — see ../README.md.
#
# This script replaced a version that cloned and `compose up`'d a list of app
# repos. That job is Komodo's now, which is why there is no REPOS array here
# and no per-app logic of any kind. Adding a service should never mean editing
# this file.
#
# Run on a fresh box:
#   curl -fsSL https://raw.githubusercontent.com/namanvashistha/homelab/main/bootstrap/deploy.sh | sudo bash
#
# Re-run any time to pull this repo and apply changes to the five services.
# Idempotent — safe to run repeatedly.

set -euo pipefail

REPO_URL="https://github.com/namanvashistha/homelab.git"

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

    log "done. Komodo deploys everything else — see README.md"
}

main "$@"
