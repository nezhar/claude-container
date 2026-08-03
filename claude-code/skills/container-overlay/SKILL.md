---
name: container-overlay
description: Persist tools you needed inside the claude-container so they're available next launch, expose in-container servers to the host, and grant the container runtime privileges it lacks. Use whenever you ran apt-get install, configured a global utility (Nix/Homebrew/asdf/cargo install -g, system Python packages), mutated the container in a way that should survive a restart, started a server (dashboard, dev server, API) the user should be able to open, or hit a failure that needs a kernel capability, a device node, a sysctl, or an env var from the host. Append to `.claude-container-overlay/Dockerfile` at the workspace root, declare fixed ports in `overlay.json` "ports", declare NAMED services in `overlay.json` "services" (preferred for HTTP servers — reachable immediately, no restart, no port collisions), add "capabilities"/"devices"/"sysctls"/"env" for runtime docker flags, or add `startup.sh` for setup that must run at every container start.
---

# claude-container overlay

The Ubuntu-based `claude-container` image is shared across all workspaces. To install project-specific tooling **persistently** without forking the base image, maintain a `.claude-container-overlay/` directory at the workspace root. The launcher detects it, appends its `Dockerfile` to the base image's, and rebuilds a workspace-local image tagged with a content hash of the build inputs.

You almost never need to ask the user before doing this — if you just ran `apt-get install foo` and confirmed `foo` works, persisting it is the expected next step. The cost of a stale overlay is low (rebuild takes seconds when cached); the cost of forgetting and re-installing every session is high.

## Layout

```
.claude-container-overlay/
├── Dockerfile      # build fragment, appended to the base image (no FROM line)
├── overlay.json    # structured runtime config: {"ports": [...], "services": {...}}
├── startup.sh      # optional hook, run once per container start
└── skills/<name>/  # proposed skills — see the container-skills skill
```

All four parts are optional; create only what you need. The directory can be committed to the repo.

- **`Dockerfile`** — a fragment concatenated after `FROM <base-image>` during `docker build`. It executes **as root** at build time (the entrypoint switches users at runtime). The overlay directory is the **build context**, so `COPY someconf /etc/someconf` works for files you place next to the Dockerfile.
- **`overlay.json`** — runtime configuration the launcher reads: a `ports` array of mappings passed straight to `docker run -p`, a `services` object naming in-container ports (see Named services below), and the `capabilities`/`devices`/`sysctls`/`env` runtime flags (see Runtime flags below).
- **`startup.sh`** — a hook run once per container start, for setup that can't be baked into an image layer (see Startup hook below).
- **`skills/`** — skill proposals; deployed at launch, never baked into the image. Covered by the `container-skills` skill, not this one.

A legacy form — `.claude-container-overlay` as a single Dockerfile-fragment *file* with `# claude-container:port <mapping>` comments — still works. If you find one, migrate it: `mkdir` the directory, move the fragment to `Dockerfile` (dropping the port comments), and convert the port comments into `overlay.json`.

## A normal Dockerfile entry

```dockerfile
# 2026-06-18: opencv runtime libs for the camera calibration script
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
```

## Named services (preferred for HTTP servers)

When you start a web dashboard, dev server, or API inside the container that the user should be able to open, declare it by **name** in `overlay.json`:

```json
{
  "services": {"dashboard": 8099, "api": 8080}
}
```

The value is the in-container port; the entry takes effect **immediately** (no restart) and the user opens `http://dashboard.$CLAUDE_SERVICE_INSTANCE.claude.localhost/`. This is covered in full — URL forms, in-container verification, and migrating old `"ports"` entries — by the **`container-services`** skill; use that one when exposing a server. Use `"ports"` (below) only when something genuinely needs a **fixed, well-known host port** (an external device calls back in, a config file hardcodes the port, or UDP is involved).

## Fixed port forwarding

For a fixed host port, declare mappings in `overlay.json`:

```json
{
  "ports": ["8080:8080", "127.0.0.1:3000:3000", "9000:9000/udp"]
}
```

Each entry is passed straight to `docker run -p`, so any value docker accepts works: `host:container`, `ip:host:container`, a bare container port, or a `/udp` suffix. Fixed mappings take effect at the **next launch** and collide if another running container claims the same host port. `overlay.json` (like `startup.sh`) is excluded from the image hash, so **changing ports or services never triggers a rebuild** — ports only change the `-p` flags on the next `docker run`; services apply live.

## Runtime flags

Some failures aren't missing software — they're missing container privileges. A VPN client can't create a TUN interface, a flasher can't see a USB device, a daemon needs a sysctl, a tool needs a token that only exists on the host. Those are `docker run` concerns, so they go in `overlay.json`, not the Dockerfile:

```json
{
  "capabilities": ["NET_ADMIN"],
  "devices": ["/dev/net/tun", "/dev/bus/usb:/dev/bus/usb:rwm"],
  "sysctls": {"net.ipv4.ip_forward": 1},
  "env": ["TS_AUTHKEY", "TS_HOSTNAME=worker-1"]
}
```

| Key | Becomes | Accepts |
| --- | --- | --- |
| `capabilities` | `--cap-add` | Capability names, with or without `CAP_`. `ALL` is refused. |
| `devices` | `--device` | `host[:container[:perms]]`; both paths must be under `/dev/`. |
| `sysctls` | `--sysctl` | Container-namespaced only: `net.*`, `fs.mqueue.*`, `kernel.msg*`, `kernel.sem`, `kernel.shm*`. |
| `env` | `-e` | Bare `NAME` forwards the host value; `NAME=value` sets a literal. |

This is an **allowlist**, not a passthrough. `-v`, `--privileged`, `--pid=host` and `--network=host` cannot be expressed, by design — `overlay.json` is committed with the repo and applied silently at the next launch, so it must not be able to reach the host. Don't try to work around it; if a project genuinely needs one of those, tell the user and let them decide.

Entries that don't validate are skipped with a warning and the launch continues — so if a flag seems to have no effect, read the launcher's output at startup.

**Secrets go in the bare `"NAME"` form.** The value is read from the environment that ran `claude-container` and never lands in the container's argv. Never write a token into `overlay.json` as `"NAME=<token>"` — the file is committed. If the variable isn't set on the host, the launcher warns and the container simply doesn't get it; tell the user what to export.

Like ports, these take effect at the **next launch** and never trigger a rebuild.

## Startup hook

`startup.sh` runs once per container start, immediately before Claude. Use it only for state that can't survive in an image layer — a daemon that must be running, a network to join, a socket to seed:

```bash
# .claude-container-overlay/startup.sh
set -e
sudo tailscaled --state=/var/lib/tailscale/tailscaled.state --tun=tailscale0 &
sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$(hostname)"
```

- It runs **to completion**, not backgrounded, so an unattended agent starts with the setup already done. Background the long-lived daemon *inside* the script (as above); don't let the script itself block forever.
- It runs as the **mapped non-root user**. For root, use `sudo` — which the overlay `Dockerfile` must install and grant (see the `apt-install` skill's sudo block for the drop-in).
- A hook that fails or exceeds the timeout (120s, `CLAUDE_STARTUP_TIMEOUT` to change) warns and lets the session continue. Don't rely on it to gate anything critical without checking the result.
- Installing the software still belongs in the `Dockerfile`. The hook only *starts* things.

Everything the hook needs from the host — auth keys, tokens — comes through `overlay.json`'s `env`.

## When to add a Dockerfile entry

Trigger this skill any time you run a command that mutates global container state and you want it available next session. Concrete triggers:

- `apt-get install`, `apt install`, `dpkg -i` — system packages
- `nix-env -iA`, `nix profile install`, adding a channel — Nix-managed tools
- `pip install` outside a venv (i.e., touching the system interpreter)
- `npm install -g`, `pnpm add -g`, `cargo install`, `go install` — global CLIs that don't live in the workspace
- Adding a new APT repository, downloading a binary into `/usr/local/bin`, configuring `/etc/*`
- Anything you'd otherwise have to re-do at the start of the next session

Do **not** use this for workspace-scoped state — pyproject deps, Bazel rules, pnpm workspace deps, repo-local configs. Those belong in the repo's normal manifests.

## Append, don't rewrite

**Strongly bias toward appending new `RUN` blocks to the Dockerfile rather than editing existing ones.** Docker caches each layer by the literal text of its instruction. If you edit an earlier line, every layer after it rebuilds from scratch.

Concretely:

- **Good** — adding a new package next session: append a *new* `RUN apt-get update && apt-get install -y --no-install-recommends newpkg && rm -rf /var/lib/apt/lists/*` block at the bottom.
- **Bad** — adding `newpkg` to the package list of an existing `RUN apt-get install` block. That invalidates the cached layer and every layer below it.

The only reasons to edit an existing entry:

- The whole entry is wrong (e.g., installs the wrong package). Fix in place.
- A previous overlay session added a package, you've now removed the dependency that needed it, and you want to clean up. Delete the block.
- The file has accumulated 20+ blocks and is genuinely unreadable. Consolidate, but warn the user that the next rebuild will be cold.

If you're unsure, append. A few extra layers cost ~nothing; rebuilding from scratch costs minutes.

## Patterns

### apt packages

Each apt session gets its own `RUN` block, dated for context:

```dockerfile
# 2026-06-18: ffmpeg for video pipeline tests
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*
```

Always combine `apt-get update` and `apt-get install` in the same `RUN` (otherwise a stale apt cache layer can be reused with fresh package names) and clean `/var/lib/apt/lists/*` to keep the layer small.

### Nix

If the project uses Nix, install it once at the bottom of the Dockerfile and never re-run that block. Subsequent Nix package additions belong in a `flake.nix` / `default.nix` checked into the repo, not in the overlay:

```dockerfile
# 2026-06-18: single-user Nix install (project uses flakes)
RUN curl -L https://nixos.org/nix/install -o /tmp/install-nix \
    && sh /tmp/install-nix --no-daemon --yes \
    && rm /tmp/install-nix
ENV PATH=/root/.nix-profile/bin:$PATH
```

(The base image runs as a non-root user at runtime, but the overlay executes as root during build. If you need the Nix profile available to the runtime user, set it up under `/opt` or chown after install — ask the user before going down this path.)

### A binary download

```dockerfile
# 2026-06-18: terraform 1.9.5 for infra/ scripts
RUN curl -fsSL -o /tmp/tf.zip \
        https://releases.hashicorp.com/terraform/1.9.5/terraform_1.9.5_linux_arm64.zip \
    && unzip /tmp/tf.zip -d /usr/local/bin \
    && rm /tmp/tf.zip \
    && terraform -version
```

### A config file baked into the image

Place the file next to the Dockerfile and `COPY` it (the overlay directory is the build context):

```dockerfile
# 2026-06-18: custom pip index config
COPY pip.conf /etc/pip.conf
```

## Workflow

1. You've just installed something inside the running container and confirmed it works.
2. Read `.claude-container-overlay/Dockerfile` if it exists. If not, create the directory and file. (If `.claude-container-overlay` is a legacy single file, migrate it first — see Layout above.)
3. **Append** a new `RUN` block (or `ENV`/`COPY` line) to the end. Date the comment so future-you can prune dead entries.
4. Tell the user briefly: "Persisted `<thing>` to `.claude-container-overlay/Dockerfile` — the next `claude-container` launch will rebuild the image with it baked in (~30s on first run, cached after)."
5. Don't run `docker build` yourself. The launcher handles it on next invocation.

## What the launcher does

When `claude-container` starts in a workspace containing `.claude-container-overlay/`:

1. Reads port mappings and runtime flags from `overlay.json` (runtime-only; never affects the image).
2. Hashes the base image tag + `Dockerfile` + any other files in the directory (excluding `overlay.json`, `startup.sh` and `skills/`).
3. Looks for a local image tagged `claude-container-overlay:<hash>`.
4. If it exists, uses it. If not, builds it: `FROM <base-image>` followed by the fragment, with the overlay directory as build context.
5. Runs the container as usual against that image, adding the `-p` flags, the validated runtime flags, plus a single ephemeral publish of the service mux (which backs named services).
6. Runs `startup.sh`, if present, before handing off to Claude.

Because the tag is content-addressed, switching branches that have different overlays just switches images — no rebuild needed if you've used that overlay before.

## Things that won't work

- `USER` directives in the fragment — the base image's entrypoint manages users dynamically based on `USER_UID`/`USER_GID`. Setting `USER` breaks the UID-mapping flow.
- `ENTRYPOINT` / `CMD` — same reason; the base image's entrypoint must run.
- `WORKDIR` other than `/workspace` — `/workspace` is the bind mount point.
- `COPY` of workspace files outside the overlay directory — the build context is `.claude-container-overlay/` only, and the workspace is mounted at *run* time. If you need a file in the image, copy it into the overlay directory first, but prefer not to — bind mounts are simpler.
- `COPY` of `skills/` or `overlay.json` into the image — they're excluded from the rebuild hash, so the image would silently go stale when they change.
