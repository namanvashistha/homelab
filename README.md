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
bootstrap/          Layer 1 — run on the host, by hand, rarely
  deploy.sh           installs docker, creates the caddy network, runs the below
  docker-compose.yml  caddy, cloudflared, komodo-mongo, komodo-core, komodo-periphery
  .env.example        the only secrets file on the box (5 values)

komodo/syncs/       Layer 2 — what Komodo should be running, reconciled from git
  infra.toml          the server, the redeploy poller, the two boot procedures
  apps.toml           one block per application, each from its own repo

jellyfin/           Kubernetes manifest from an earlier experiment.
                    Not managed by Komodo — compose only here.
```

### Layer 1: bootstrap

Five services, listed above, and nothing else qualifies.

These are the one thing Komodo does not apply for you, and it is not an
oversight: `komodo-periphery` is the process that runs `docker compose up`, so
a run that recreates Periphery kills the command mid-flight. Something outside
Komodo has to own them.

That something is you, occasionally:

```bash
ssh the-box
bash ~/homelab/bootstrap/deploy.sh    # pull + compose up -d, idempotent
```

Editing `bootstrap/docker-compose.yml` and pushing changes nothing until that
runs. In practice it is a few times a year, mostly Komodo version bumps — and
those are exactly the changes worth watching rather than waking up to.

There *is* a way to automate it (a one-shot in its own compose project, which
recreates Core and Periphery from outside the blast radius). It was built here
and then removed: it worked, but its exit code is invisible to Komodo, so a
failed apply looks identical to a successful one. Not a good trade for five
containers that change twice a year. `git log` has it if you want it back.

### Layer 2: Komodo

Everything else. Komodo reads `komodo/syncs/*.toml`, diffs it against what it is
running, and applies the difference.

The `poll-git-redeploy` procedure runs every ten minutes, in two stages:

1. **`RunSync`** — applies this repo's declarations. Without it a sync only
   *notices* a change, parks in `Pending`, and waits for someone to press
   Execute in the UI. This is that press, on a schedule.
2. **`BatchDeployStackIfChanged`** — redeploys any stack whose own source repo
   has new commits.

Stages run in order, so a stack added to `apps.toml` exists by the time stage 2
tries to deploy it. Both happen in one commit's worth of work: push, wait ten
minutes.

Adding a service does not touch layer 1. It never should.

**The one thing that cannot be declared is the sync itself.** A sync holds a
lock on its own resource while running, so a `[[resource_sync]]` block for
`homelab` inside `komodo/syncs` fails every run with `ResourceSync busy` — and
because a failed stage aborts the procedure, stage 2 then never runs and
nothing redeploys at all. It is created by hand in the UI, once; its settings
are written down at the top of `infra.toml` so it stays reproducible.

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
#      match tags    homelab      <- set this BEFORE enabling delete
#      delete        on
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

Push. The poller picks it up within ten minutes. The app's own compose carries
its `caddy:` label and joins the external `caddy` network, so routing
configures itself — nothing to add here or in Cloudflare.

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
- **One compose file owns one concern.** One stack per thing that can fail on
  its own — that is what lets Komodo redeploy one without touching the rest.
- **Named volumes, not *relative* bind mounts,** in `stacks/*.yml`. Komodo clones
  this repo to `/etc/komodo/stacks/<name>/`, so `./data` silently anchors
  wherever the clone lands. Absolute host paths are fine and sometimes required
  — `self-update.yml` mounts `/root/homelab` and the docker socket on purpose,
  because the daemon, not the container, resolves them.
- **Tag every declared resource `homelab`.** The sync runs `delete = true`
  scoped by `match_tags = ["homelab"]`. Untagged means out of scope: never
  created, never deleted, silently ignored. Tagged and missing from git means
  deleted. CI enforces the tag.
- **Comments explain *why*, not *what*.** The compose files say what; the
  reasoning behind a weird pinned tag or a missing `ports:` is the part that is
  expensive to reconstruct.

## Operating notes

- **Where things live on the host:** this repo at `/root/homelab`, Komodo's
  clones and runtime at `/etc/komodo/stacks/<name>/`, database backups at
  `/etc/komodo/backups`. That first path is assumed in two places —
  `HOMELAB_DIR` on the `self-update` stack in `infra.toml`, and `BASE_DIR` in
  `deploy.sh`. Move the checkout and both need updating.
- **Redeploy everything by hand:** Komodo → Procedures → `poll-git-redeploy` →
  Run. That runs the sync and every changed stack, `self-update` included.
- **Force a bootstrap apply without a commit:** Komodo → Stacks →
  `self-update` → Deploy. Read its container logs to see what it did.
- **The bootstrap stack is broken and Komodo is down with it:** the one case
  nothing here recovers from. SSH in and run `bash ~/homelab/bootstrap/deploy.sh`.
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
