# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Declarative config for one Ubuntu home server behind CGNAT. No application code —
only compose files, Komodo sync TOML, one bash bootstrap script, and one CI
workflow. There is nothing to build or test locally; changes are validated by
parsing, and applied on the host.

`README.md` is the operator's manual (first-run, disaster recovery, alerting
rationale). This file is the orientation for editing the repo.

## Commands

Everything CI does, runnable locally:

```bash
# compose files parse and interpolate (same loop as .github/workflows/validate.yml)
for f in bootstrap/docker-compose.yml services/*.yml; do
  CF_TUNNEL_TOKEN=x KOMODO_DB_PASSWORD=x KOMODO_ADMIN_PASSWORD=x \
  KOMODO_JWT_SECRET=x KOMODO_WEBHOOK_SECRET=x \
  docker compose -f "$f" config -q
done

# sync TOML parses and passes the invariant checks
python3 -c 'import pathlib,tomllib; [tomllib.loads(p.read_text()) for p in pathlib.Path("komodo/syncs").rglob("*.toml")]'
```

Applying changes (on the host, over ssh — never from this checkout):

```bash
bash ~/homelab/bootstrap/deploy.sh   # layer 1 only; idempotent, root required
```

Layer 2 needs nothing: push to `main`, and the `sync-and-deploy` procedure
applies it within ten minutes. To skip the wait: Komodo UI → Procedures →
`sync-and-deploy` → Run.

## Architecture: two layers, one rule

> Anything Komodo needs in order to run cannot be deployed by Komodo.

That constraint decides which file a change belongs in.

**Layer 1 — `bootstrap/`.** caddy, cloudflared, komodo-mongo, komodo-core,
komodo-periphery. Applied only by running `deploy.sh` on the host. Editing
`bootstrap/docker-compose.yml` and pushing changes nothing. Periphery is the
process that runs `docker compose`, so it cannot recreate itself; that is why
this layer is manual and why it must stay at five services.

**Layer 2 — `komodo/syncs/*.toml`.** Everything else. Komodo reads the whole
directory (recursively), diffs against reality, applies. Split by kind:
- `infra.toml` — the `Local` server, the `sync-and-deploy` procedure, the Slack alerter
- `projects.toml` — apps whose source I own. Declarations only: the compose is `docker-compose.homelab.yaml` **in the app's own repo**, and the image is `ghcr.io/namanvashistha/<name>`
- `services.toml` — off-the-shelf apps. The compose is `services/<name>.yml` in this repo, and the image is a vendor's

Same flags for both. Two differences, and they follow from one question — do I
own the source?

**Where the compose lives.** A service has no repo of its own, so its compose
lives here. A project does, so its compose lives there, beside the code it
describes: a change needing both (a new env var, a new port) is one commit
rather than two that cannot merge atomically. The cost, worth knowing before you
go looking: this repo alone no longer describes the full topology of the box,
and CI here cannot validate those files. It is a per-stack choice — `repo` is a
field on every block, so an app can move back in whenever the trade flips.

**Why `docker-compose.homelab.yaml` and not the repo's `docker-compose.yml`.**
That one is the dev compose — builds from the Dockerfile, publishes ports to
localhost. This one is the deployed compose — pulls the published image,
`expose:` rather than `ports:`, carries the caddy labels. Different jobs.

**The box never builds.** Each project's repo builds on push and pushes to
ghcr.io; the box only pulls. That keeps build CPU and dangling images off the
host, and is what let the CPU alerts in `infra.toml` be turned back on.

The `sync-and-deploy` procedure runs two ordered stages every 10 min: `RunSync`
(applies this repo — a sync otherwise only goes *Pending* and waits for a human
to click Execute) then `BatchDeployStackIfChanged`. Order matters: a stack added
to `projects.toml` must exist before stage 2 can deploy it.

Stage 2 is the **config**-change trigger, not the deploy trigger. Images are
handled by `auto_update`, which redeploys on a new digest. Stage 2 exists for
the case nothing else covers: a commit that changes a compose file without
changing an image.

**Routing is label-driven, not configured here.** Cloudflare's wildcard sends
`*.namanvashistha.com` to `caddy:80`; caddy-docker-proxy watches the docker
socket and picks up any container carrying a `caddy:` label on the external
`caddy` network. A new service needs no Caddy edit and no Cloudflare edit.

## Adding a project or a service

One question: **do I own the source?** If yes it is a project, if no it is a
service. Neither touches layer 1, and neither needs host access or a UI click.

**Projects only, first — in the app's own repo:**

1. A workflow that builds on push to the default branch and pushes both
   `:latest` and `:<git-sha>` to `ghcr.io/namanvashistha/<name>`. The sha tag is
   the rollback handle — `latest` alone cannot be rolled back.
2. Make the ghcr package public, or give Komodo a read-only PAT. A private
   package fails the deploy with an auth error that looks nothing like the cause.

**Then — two files, in two different places for a project.**

1. The compose. For a project, `docker-compose.homelab.yaml` in the app's repo;
   for a service, `services/<name>.yml` here. Either way modelled on
   `services/whoami.yml`:

```yaml
services:
  <name>:
    # project: ghcr.io/namanvashistha/<name>:latest    service: vendor/image:tag
    image: ghcr.io/namanvashistha/<name>:latest
    container_name: <name>
    restart: unless-stopped
    expose: ["8080"]                  # never `ports:`
    networks: [caddy]
    labels:
      caddy: http://<name>.namanvashistha.com   # http:// — auto_https is off
      caddy.reverse_proxy: "{{upstreams 8080}}"
    volumes:
      - <name>-data:/data             # named volume, never ./data

networks:
  caddy:
    external: true

volumes:
  <name>-data:
```

2. A block in `komodo/syncs/projects.toml` or `services.toml`, copied from the
   commented template at the top of that file. Only `repo` and the file path
   differ between the two:

```toml
[[stack]]
name = "<name>"
description = "..."
tags = ["app"]

[stack.config]
server = "Local"
git_provider = "github.com"

# project — the compose is in the app's repo:
repo = "namanvashistha/<name>"
branch = "main"                                  # check it; some are `master`
file_paths = ["docker-compose.homelab.yaml"]

# service — the compose is in this repo:
# repo = "namanvashistha/homelab"
# branch = "main"
# run_directory = "services"
# file_paths = ["<name>.yml"]

run_build = false          # the box never builds
auto_pull = true           # published image, so pulling is possible and wanted
poll_for_updates = true
auto_update = true         # redeploy on a new image digest
```

**Then:**

1. Run the two validation commands above. CI runs the same checks on push, and
   will reject a `file_paths` entry that does not exist — but only for stacks
   sourced from this repo. A project's compose is unverifiable from here, so a
   typo in `docker-compose.homelab.yaml` surfaces as a failed deploy instead.
2. Push both repos if it is a project.
3. Wait ≤10 min, or force it: Komodo → Procedures → `sync-and-deploy` → Run.
4. Confirm at `https://<name>.namanvashistha.com`. If it does not answer, hit
   `whoami.namanvashistha.com` first — that isolates tunnel → caddy → container
   from a problem in the service itself.

**If it needs a secret:** add it in Komodo (Settings → Variables, mark secret),
then reference it from that stack's block — not from the compose file:

```toml
environment = """
SOMETHING_TOKEN=[[SOMETHING_TOKEN]]
"""
```

**Naming:** the stack name, the repo name, and the subdomain should all match.
Komodo clones to `/etc/komodo/stacks/<stack-name>/`, so the stack name is what
you look for on disk — and it is also the compose project name, which is what
every volume gets prefixed with. Renaming a stack renames its volumes, which
detaches the data silently rather than failing.

## Invariants (CI enforces these; breaking them breaks the box quietly)

- **No `[[resource_sync]]` block anywhere in `komodo/syncs/`.** A sync holds a
  lock on itself, so it fails every run with `ResourceSync busy` — and a failed
  stage aborts the procedure, so nothing redeploys at all. The `homelab` sync is
  hand-created in the UI; its settings are recorded at the top of `infra.toml`.
- **`auto_pull = false` whenever `run_build = true`.** `compose pull` fails
  outright on a locally built image. Nothing should set `run_build` at all now —
  the box does not build — but the check stays as a guard.
- **Every stack needs `server` and either `repo` or `files_on_host`.**
- **A stack sourced from this repo must point at a compose file that exists.**
  `run_directory` + `file_paths` is resolved against the checkout, so a typo
  fails CI instead of failing a deploy ten minutes after a push. Projects are
  skipped — their compose is in another repo and is unverifiable from here.
- **`sync-and-deploy` keeps a non-empty, enabled `schedule`.** Disable it and
  no later commit can turn it back on — the thing that would apply the fix is
  the thing that is off.

Not CI-checked, but equally load-bearing:

- **`expose:` plus caddy labels, never `ports:`** in any compose file. A host
  port bypasses Cloudflare Access and publishes to the LAN.
- **Named volumes, never relative bind mounts** (`./data`) in Komodo-deployed
  composes. Komodo clones each stack to `/etc/komodo/stacks/<name>/`, so a
  relative path anchors wherever the clone landed. Absolute host paths are fine.
- **`delete` stays off on the sync**, so removing a block stops managing a
  resource without removing it — clean up in the UI.
- **One stack per thing that can fail on its own.** That is what lets Komodo
  redeploy one without touching the rest.

## Secrets

Two stores, and the split is deliberate. `bootstrap/.env` (five values, host-only,
gitignored by a deliberately broad `bootstrap/.env*` pattern) holds only what is
needed to *start* Komodo. Everything downstream lives in Komodo's Variables &
Secrets and is referenced from TOML as `[[NAME]]`, which Komodo writes to a
`.env` beside the compose file at deploy time. Never add a secret value to this
repo — it is public.

## Conventions

Comments explain **why**, not what, and most encode a failure that actually
happened — the `komodo.skip` labels, the TCP-not-HTTP healthcheck on Caddy, the
`alert_types` ordering note in `infra.toml`. Preserve that reasoning rather than
tidying it away.

**But keep them brief.** A few lines, not paragraphs. State the reason and the
consequence and stop — no narration of what was tried, no restating the code
below it. If an explanation genuinely needs twenty lines it belongs in
`README.md`, with the comment pointing at it. Long comments in a config file go
stale silently, and this repo has already carried notes that were confidently
wrong for months.

`README.md` documents a `jellyfin/` directory that is not present in the working
tree — a leftover, not a missing file.

**The five projects are declared but not yet deployable.** `apps.toml` became
`projects.toml` and its blocks were flipped from build-on-the-box to
pull-from-ghcr, but no app repo has a `docker-compose.homelab.yaml` or a
published image yet. Each stack will fail on the missing file until its repo
catches up. `git show HEAD:komodo/syncs/apps.toml` has the old
build-from-source blocks if a rollback is needed.

Note for limedb: it needs **two** images, not one — the repo builds `./web` from
its own Dockerfile, so its CI has to push `limedb` and `limedb-web`.
