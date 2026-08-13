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

services/           Layer 2 — compose files for off-the-shelf apps
  <name>.yml            image from a vendor, no repo of its own

komodo/syncs/       Layer 2 — what Komodo should be running, reconciled from git
  infra.toml          the server, the poller, and the Slack alerter
  projects.toml       one block per app of mine — compose lives in ITS repo
  services.toml       one block per compose in services/
```

**Projects vs services** is one question: do I own the source? A service does
not have a repo of its own, so its compose lives here. A project does, so its
compose is `docker-compose.homelab.yaml` in that repo, beside the code it
describes — a change needing both is one commit instead of two that cannot merge
atomically. The cost, stated plainly: this repo alone no longer describes the
whole box. It is a per-stack choice, and `repo` is a field on every block.

That file is separate from the repo's own `docker-compose.yml`, which is the
dev compose — builds from the Dockerfile, publishes to localhost. The homelab
one pulls the published image, exposes rather than publishes, and carries the
caddy labels.

**Nothing builds on the box.** Each project's repo builds on push and pushes to
ghcr.io; the box only pulls. Building here was what made CPU alerts unusable and
what filled the disk with dangling images.

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

The `sync-and-deploy` procedure runs every ten minutes, in two stages:

1. **`RunSync`** — applies this repo's declarations. Without it a sync only
   *notices* a change, parks in `Pending`, and waits for someone to press
   Execute in the UI. This is that press, on a schedule.
2. **`BatchDeployStackIfChanged`** — redeploys any stack whose **compose file
   contents** changed. Not commits: it diffs the file, so a commit touching only
   application source does nothing here.
3. **`GlobalAutoUpdate`** — pulls newer image digests and redeploys the stacks
   that have `auto_update`. This is what deploys application code, since a code
   change moves the image and not the compose. Komodo's default install runs
   this once a day at 03:00; running it here puts code on the same ten-minute
   loop as everything else.

Stages run in order, so a stack added to `projects.toml` exists by the time stage 2
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
#      delete        off          <- leave it off, see Conventions
#    Save, then EXECUTE. Save only stages the diff; Execute applies it.
```

That single Execute creates the server, the poller, and every stack. From then
on the UI is for looking, not for editing.

## Adding a project or a service

One question: **do I own the source?** If yes it is a project, if no it is a
service.

**A project, first** — the image has to exist before the box can pull it. In the
app's own repo, add a workflow that builds on push to the default branch and
pushes both `:latest` and `:<git-sha>` to `ghcr.io/namanvashistha/<name>`. The
sha tag is the rollback handle; `latest` alone cannot be rolled back to
anything. Then make the ghcr package public, or give Komodo a read-only PAT — a
private package fails the deploy with an auth error that looks nothing like the
cause.

**Both kinds** — two files, though for a project they are in two repos:

- the compose — `docker-compose.homelab.yaml` in the app's repo, or
  `services/<name>.yml` here
- a block in the matching `komodo/syncs/*.toml`, copied from the template at the
  top of it

Each is its own stack, so a bad image in one cannot fail the others' deploys.

Push. The poller picks it up within ten minutes. The compose carries its own
`caddy:` label and joins the external `caddy` network, so routing configures
itself — nothing to add here or in Cloudflare.

Two rules for the compose: `expose:` plus caddy labels, never `ports:` (a host
port bypasses Cloudflare Access), and named volumes, never `./data` (Komodo
clones the repo, so a relative path anchors wherever the clone landed). A
relative mount of a file that is *in* that repo — foodly's `./setup.sql` — is
fine, because the clone is exactly where it lives.

Everything runs a published image, mine or a vendor's, so `run_build = false`,
`auto_pull = true`, `poll_for_updates = true` and `auto_update = true` are
correct either way. `auto_update` is what deploys a new image, and it is the
right trigger here because a digest change cannot arrive before CI finishes.

**Secrets** go in Komodo (Settings → Variables), never in this repo, and are
referenced as `[[NAME]]` from a stack's `environment`. Komodo writes them to a
`.env` beside the compose file at deploy time. Note the honest caveat: variables
marked secret are hidden in the UI and logs but are **not encrypted at rest** in
Mongo. Their security is the database's security.

## Conventions worth keeping

- **The box does not build.** Images come from ghcr.io, built by the app repo's
  own CI. If anything ever sets `run_build = true` again it must also set
  `auto_pull = false`, because `compose pull` fails outright on a locally built
  image — CI checks that pairing.
- **A stack sourced from this repo must name a compose file that exists.**
  CI resolves `run_directory` + `file_paths` against the checkout, so a typo
  fails there rather than as a failed deploy ten minutes after a push.
- **One compose file owns one concern.** One stack per thing that can fail on
  its own — that is what lets Komodo redeploy one without touching the rest.
- **Named volumes, not *relative* bind mounts,** in any compose file Komodo
  deploys. It clones each stack to `/etc/komodo/stacks/<name>/`, so `./data`
  silently anchors wherever the clone landed. Absolute host paths are fine —
  the daemon resolves those, not the container.
- **`delete` stays off on the sync.** With it on, Komodo removes anything not
  declared in these files — and the sync itself cannot be declared here, so it
  would target itself and fail every run with `ResourceSync busy`, aborting the
  procedure. Scoping it safely needs `match_tags` plus a tag on every resource,
  which is more machinery than a homelab deserves. Cost of leaving it off:
  deleting a block from git stops managing the resource but does not remove it
  — do that in the UI.
- **Comments explain *why*, not *what*.** The compose files say what; the
  reasoning behind a weird pinned tag or a missing `ports:` is the part that is
  expensive to reconstruct.

## Alerts

Two halves, both declared in `infra.toml`: the `[[server]]` and stack configs
decide **what gets raised**, and the `[[alerter]]` decides **where it goes**.
Without an enabled alerter, Komodo computes every alert and silently drops it —
the state this instance was in until Slack was wired up.

The webhook URL is the only part kept out of git. It is a Komodo Variable,
referenced as `[[SLACK_WEBHOOK_URL]]` and resolved at **send** time:
`bin/core/src/alert/slack.rs` runs `interpolate_string` over the URL before
each post. So the secret never enters this repo, and rotating it is a Variables
edit with no redeploy.

**Prerequisite:** Settings → Variables → `SLACK_WEBHOOK_URL`, marked secret,
holding your Slack app's incoming-webhook URL. Without it the alerter posts to
the literal string and fails.

The alert types it forwards, and why each earns a Slack message:

- `ServerUnreachable` — the box or Periphery is gone. The one that matters.
- `ServerDisk` — 80% warning, 90% critical, set in `infra.toml`.
- `StackStateChange` — an app went down, unhealthy, or recovered.
- `ProcedureFailed` — the poller broke, so git and reality have stopped
  converging. Otherwise silent, and easy to miss for days.
- `ResourceSyncPendingUpdates` — the sync computed a diff it could not apply.
  This is the shape of the `ResourceSync busy` failure that ran red for hours
  unnoticed.
- `ServerVersionMismatch` — Core and Periphery on different versions, which is
  what a half-applied bootstrap update looks like.
- `BuildFailed` — only once Builds are in use.
- `Test` — so the alerter's Test button actually proves the path end to end.

Deliberately **not** enabled, with the reasoning recorded in `infra.toml`: CPU
alerts (six stacks build from source; every deploy pegs the CPU) and memory
alerts (ZFS makes Periphery report 0.00 GB used, so no threshold can trigger).

Use the alerter's Test button before trusting any of it.

## Operating notes

- **Where things live on the host:** this repo at `~/homelab` (`BASE_DIR` in
  `deploy.sh`), Komodo's clones and runtime at `/etc/komodo/stacks/<name>/`,
  database backups at `/etc/komodo/backups`.
- **Apply everything now, without waiting for the schedule:** Komodo →
  Procedures → `sync-and-deploy` → Run. That is the sync plus every changed
  stack.
- **Apply a bootstrap change:** `bash ~/homelab/bootstrap/deploy.sh` on the box.
  Nothing else does this — see Layer 1.
- **The bootstrap stack is broken and Komodo is down with it:** same command.
  It is the recovery path precisely because it needs nothing but docker and git.
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
