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
# Layer 1 is the one thing Komodo does not apply for you, and it cannot:
# Periphery would be restarting the Core it reports to, and killing its own
# compose command to do it. So this script installs a cron entry that re-runs
# itself every ten minutes, matching the cadence Komodo reconciles everything
# else at — push to bootstrap/ and it lands without an ssh session.
#
# Idempotent, and it has to be to run that often: `compose up -d` on an
# unchanged stack is a no-op, the periphery binary is downloaded only when the
# stamped version differs, and the agent is restarted only when something it
# reads actually changed.

set -euo pipefail

REPO_URL="https://github.com/namanvashistha/homelab.git"
PERIPHERY_SETUP_URL="https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py"
VERSION_STAMP="/etc/komodo/periphery.version"
CRON_FILE="/etc/cron.d/homelab-deploy"
LOCK_FILE="/run/lock/homelab-deploy.lock"
INSTALL_CRON=1

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
    local version arch tmp unit restart=0
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

    mkdir -p /etc/komodo

    # `deploy.sh` is how the agent gets updated — Core is pinned by
    # KOMODO_IMAGE_TAG and a drift raises ServerVersionMismatch. But the cron
    # re-enters this every ten minutes, so the version is stamped and compared
    # first: an unconditional install would pull ~50 MB and restart the agent
    # out from under whatever deploy it was running. Stamped rather than asked
    # of the binary, which has no --version to trust.
    # Staged in a temp file so a failed download cannot leave a truncated binary.
    if [ -x /usr/local/bin/periphery ] && [ "$(cat "$VERSION_STAMP" 2>/dev/null)" = "$version" ]; then
        log "periphery $version already installed"
    else
        log "installing periphery $version ($arch)"
        tmp=$(mktemp)
        curl -fsSL "https://github.com/moghtech/komodo/releases/download/$version/periphery-$arch" \
            -o "$tmp" || fail "periphery $version download failed — check the tag exists"
        chmod +x "$tmp"
        mv "$tmp" /usr/local/bin/periphery
        echo "$version" >"$VERSION_STAMP"
        restart=1
    fi

    # Written once. Everything else takes the binary's defaults; these three
    # are the ones that are wrong by default here.
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
        restart=1
    fi

    # Pairing. Core learns this agent's public key from the onboarding key and
    # stores it in mongo, so this is needed once per box, not once per run.
    if [ -n "${PERIPHERY_ONBOARDING_KEY:-}" ]; then
        sed -i '/^onboarding_key = /d' /etc/komodo/periphery.config.toml
        echo "onboarding_key = \"$PERIPHERY_ONBOARDING_KEY\"" \
            >>/etc/komodo/periphery.config.toml
        restart=1
    elif ! grep -q '^onboarding_key = ' /etc/komodo/periphery.config.toml; then
        log "note: agent unpaired. Komodo -> Servers -> onboarding key, then"
        log "      bash $BASE_DIR/bootstrap/deploy.sh --onboarding-key O-..."
    fi

    # WantedBy=default.target matches upstream's unit. Written to a temp file
    # and compared, so an unchanged unit costs no daemon-reload and no restart.
    unit=$(mktemp)
    cat >"$unit" <<'EOF'
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
    chmod 644 "$unit"
    if cmp -s "$unit" /etc/systemd/system/periphery.service; then
        rm -f "$unit"
    else
        mv "$unit" /etc/systemd/system/periphery.service
        systemctl daemon-reload
        restart=1
    fi

    systemctl enable --quiet periphery
    if [ "$restart" -eq 1 ] || ! systemctl is-active --quiet periphery; then
        systemctl restart periphery
    fi
}

# Every ten minutes, matching the cadence the `sync-and-deploy` procedure
# reconciles layer 2 at. Written as a /etc/cron.d file rather than `crontab -e`
# so it is declarative: root's crontab is invisible in this repo, whereas this
# file is rewritten from here on every run and drift cannot survive.
install_cron() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
# Written by bootstrap/deploy.sh — do not edit; the next run overwrites it.
# To stop the schedule, delete this file AND stop running deploy.sh by hand,
# or pass --no-cron.
#
# HOMELAB_DIR is spelled out because cron runs as root with HOME=/root and no
# SUDO_USER, so the script would otherwise look for the checkout in the wrong
# home. PATH because cron's default has no /usr/local/bin.
#
# flock -n: a run that overruns ten minutes — a slow image pull, a long build —
# is skipped rather than stacked on top of the one still going.
#
# Output goes to the journal (journalctl -t homelab-deploy) rather than a file,
# so it rotates itself. That also means cron never sees a non-zero exit, which
# is fine: MAILTO is empty and there is no MTA on this box to mail anyway.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/10 * * * * root HOMELAB_DIR=$BASE_DIR flock -n $LOCK_FILE /bin/bash $BASE_DIR/bootstrap/deploy.sh 2>&1 | logger -t homelab-deploy
EOF
    chmod 644 "$tmp"
    if cmp -s "$tmp" "$CRON_FILE"; then
        rm -f "$tmp"
        return
    fi
    log "installing $CRON_FILE (every 10 min)"
    mkdir -p "$(dirname "$CRON_FILE")"
    mv "$tmp" "$CRON_FILE"
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
            # Removing $CRON_FILE by hand does not stick — the next manual run
            # writes it back. This is the off switch.
            --no-cron)
                INSTALL_CRON=0
                shift
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
    # install_periphery refetches the agent at `latest` every run, but `up -d`
    # reuses a komodo-core:2 image already on the box — so the agent drifts
    # ahead of Core and the server sits in ServerVersionMismatch. Pull the
    # pinned Core tag forward so both halves move together. Only this service:
    # mongo, caddy and cloudflared all float on untagged or `ci` tags, and a
    # surprise major bump is not what re-running this script is for.
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull komodo-core
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans

    # After compose, so Core is listening on 127.0.0.1:9120 when Periphery dials.
    install_periphery

    if ! systemctl is-active --quiet periphery; then
        log "WARNING: periphery is not running — journalctl -u periphery"
    fi

    # Last, so a box that cannot finish a first run does not start rerunning
    # the failure every ten minutes.
    if [ "$INSTALL_CRON" -eq 1 ]; then
        install_cron
    else
        log "skipping cron install (--no-cron)"
    fi

    log "done. Komodo deploys everything else — see README.md"
}

main "$@"
