# homelab

Everything running on the home server, declared in git.

One Ubuntu box behind CGNAT. No public IP, no open ports — ingress arrives
through a Cloudflare tunnel that dials out. Services are reached at
`*.namanvashistha.com`.

## The one rule

> **Anything Komodo needs in order to run cannot be deployed by Komodo.**

Komodo cannot recreate the container it is executing from, and it cannot serve
a UI through a proxy it just restarted. That single constraint decides where
every service goes, and it is the reason this repo has two layers instead of
one.

## Layout

```
bootstrap/          Layer 1 — run by hand on the host, rarely
  deploy.sh           installs docker, creates the caddy network, runs the below
  docker-compose.yml  caddy, cloudflared, komodo-mongo, komodo-core, komodo-periphery
  .env.example        the only secrets file on the box (5 values)

stacks/             Layer 2 — compose files Komodo deploys from this repo
  monitoring.yml      uptime-kuma, autokuma, beszel

komodo/syncs/       Layer 2 — what Komodo should be running
  infra.toml          the sync itself, the server, the redeploy poller, infra stacks
  apps.toml           one block per application, each from its own repo

jellyfin/           Kubernetes manifest from an earlier experiment.
                    Not managed by Komodo — compose only here.
```

### Layer 1: bootstrap

Five services, listed above, and nothing else qualifies. They do not
auto-update: changing them means editing this repo and re-running `deploy.sh`
on the host. That is deliberate — these are exactly the things you don't want
redeploying themselves unattended.

### Layer 2: Komodo

Everything else. Komodo reads `komodo/syncs/*.toml`, diffs it against what it
is running, and applies the difference. A `poll-git-redeploy` procedure runs
every two minutes and redeploys any stack whose source repo has new commits.

Adding a service does not touch layer 1. It never should.

## First run on a fresh box

```bash
# 1. bootstrap
curl -fsSL https://raw.githubusercontent.com/namanvashistha/homelab/main/bootstrap/deploy.sh | sudo bash
# fails on the missing .env — that is the prompt to write it:
sudo cp ~/homelab/bootstrap/.env.example ~/homelab/bootstrap/.env
sudo vi ~/homelab/bootstrap/.env          # openssl rand -hex 32, three times
curl -fsSL https://raw.githubusercontent.com/namanvashistha/homelab/main/bootstrap/deploy.sh | sudo bash

# 2. Cloudflare: point the tunnel's wildcard at the proxy
#    Zero Trust -> Networks -> Tunnels -> Public Hostnames
#    *.namanvashistha.com  ->  HTTP  ->  caddy:80
#    Then: Zero Trust -> Access -> Applications -> policy on komodo.namanvashistha.com

# 3. Komodo, at https://komodo.namanvashistha.com
#    Servers should already show `Local`, connected.
#    Syncs -> New Sync, named exactly `homelab`:
#      git provider  github.com
#      repo          namanvashistha/homelab
#      branch        main
#      resource path komodo/syncs
#    Save, then EXECUTE. Save only stages the diff; Execute applies it.
```

That single Execute creates the server, the poller, and every stack. From then
on the UI is for looking, not for editing.

## Adding a service

**An app with its own repo** — append to `komodo/syncs/apps.toml`:

```toml
[[stack]]
name = "thing"
tags = ["app"]

[stack.config]
server = "Local"
git_provider = "github.com"
repo = "namanvashistha/thing"
branch = "main"
file_paths = ["docker-compose.yml"]
run_build = true      # builds from a Dockerfile in-tree
auto_pull = false     # MUST be false when run_build is true
poll_for_updates = false
```

Push. The poller picks it up within two minutes. The app's own compose carries
its `caddy:` label and joins the external `caddy` network, so routing and
uptime monitoring configure themselves.

**Something with no repo of its own** — put the compose in `stacks/`, then
declare it in `infra.toml` with `run_directory = "stacks"` and
`file_paths = ["yours.yml"]`.

**Secrets** go in Komodo (Settings → Variables), never in this repo, and are
referenced as `[[NAME]]` from a stack's `environment`. Komodo writes them to a
`.env` beside the compose file at deploy time. Note the honest caveat: variables
marked secret are hidden in the UI and logs but are **not encrypted at rest** in
Mongo. Their security is the database's security.

## Conventions worth keeping

- **`auto_pull = false` whenever `run_build = true`.** `compose pull` fails
  outright on a locally built image. CI checks this.
- **One compose file owns one concern.** Splitting `monitoring` from the apps is
  what lets Komodo redeploy one without touching the other.
- **Named volumes, not bind mounts,** in `stacks/*.yml`. Komodo clones this repo
  to `/etc/komodo/stacks/<name>/`, so a relative bind mount silently anchors
  wherever the clone lands. Volumes keep a stack relocatable.
- **`delete = false` on the sync, for now.** Komodo's delete mode walks *every*
  resource type and removes anything not declared in these files — including the
  Procedures Core creates on first boot. Turn it on only once everything on the
  instance is declared here.
- **Comments explain *why*, not *what*.** The compose files say what; the
  reasoning behind a weird pinned tag or a missing `ports:` is the part that is
  expensive to reconstruct.

## Operating notes

- **Where things live on the host:** this repo at `~/homelab`, Komodo's clones
  and runtime at `/etc/komodo/stacks/<name>/`, database backups at
  `/etc/komodo/backups`.
- **Redeploy everything by hand:** Komodo → Procedures → `poll-git-redeploy` →
  Run.
- **The Server disappeared:** it is only auto-created on a Core startup where no
  server exists at all. Either restart `komodo-core`, or re-run the sync — it is
  declared in `infra.toml` precisely so this is recoverable.
- **Webhooks instead of polling:** add a Cloudflare Access **Bypass** policy for
  `/listener/*` (GitHub cannot log in), then paste each stack's webhook URL into
  its repo with `KOMODO_WEBHOOK_SECRET` as the secret. Komodo verifies the
  signature itself, so the bypass is safe.
- **Disaster recovery:** losing the `komodo-mongo-data` volume loses users and
  history, not the stacks — re-run `deploy.sh`, recreate the `homelab` sync,
  Execute, and everything comes back. Losing `komodo-keys` breaks Core↔Periphery
  trust until both containers are recreated together. The secrets in
  `bootstrap/.env` and Komodo's Variables are the only things not reproducible
  from this repo. Back those up separately.
