---
name: container-overlay
description: Persist tools you needed inside the claude-container so they're available next launch. Use whenever you ran apt-get install, configured a global utility (Nix/Homebrew/asdf/cargo install -g, system Python packages), or otherwise mutated the container in a way that should survive a restart. Append to `.claude-container-overlay` at the workspace root — the launcher rebuilds the image with that file appended to its Dockerfile on the next run.
---

# claude-container overlay

The Ubuntu-based `claude-container` image is shared across all workspaces. To install project-specific tooling **persistently** without forking the base image, write a Dockerfile fragment to `.claude-container-overlay` at the workspace root. The launcher detects this file, appends it to the base Dockerfile, and rebuilds a workspace-local image tagged with a hash of the overlay contents.

You almost never need to ask the user before doing this — if you just ran `apt-get install foo` and confirmed `foo` works, persisting it is the expected next step. The cost of a stale overlay is low (rebuild takes seconds when cached); the cost of forgetting and re-installing every session is high.

## When to use this skill

Trigger this skill any time you run a command that mutates global container state and you want it available next session. Concrete triggers:

- `apt-get install`, `apt install`, `dpkg -i` — system packages
- `nix-env -iA`, `nix profile install`, adding a channel — Nix-managed tools
- `pip install` outside a venv (i.e., touching the system interpreter)
- `npm install -g`, `pnpm add -g`, `cargo install`, `go install` — global CLIs that don't live in the workspace
- Adding a new APT repository, downloading a binary into `/usr/local/bin`, configuring `/etc/*`
- Anything you'd otherwise have to re-do at the start of the next session

Do **not** use this for workspace-scoped state — pyproject deps, Bazel rules, pnpm workspace deps, repo-local configs. Those belong in the repo's normal manifests.

## The overlay file

Path: `<workspace-root>/.claude-container-overlay`

Format: a Dockerfile fragment that gets concatenated to the end of the base image's Dockerfile during `docker build`. It executes **as root** during build (the base image's `USER` directive isn't set; the entrypoint switches users at runtime).

A normal entry looks like:

```dockerfile
# 2026-06-18: opencv runtime libs for the camera calibration script
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
```

## Port forwarding

The overlay can also publish container ports to the host, so a dev server, web UI,
or debugger running inside the container is reachable from your machine. Declare
mappings with directive comments anywhere in the overlay file:

```dockerfile
# claude-container:port 8080:8080
# claude-container:port 127.0.0.1:3000:3000
# claude-container:port 9000:9000/udp
```

Everything after `claude-container:port` is passed straight to `docker run -p`, so
any value docker accepts works: `host:container`, `ip:host:container`, a bare
container port, or a `/udp` suffix. These are plain Dockerfile comments, so they
don't affect the build — the launcher reads them and adds the `-p` flags when it
starts the container. Pair the port directive with whatever installs/starts the
service (e.g. a `RUN` that installs it) so the mapping and the server stay together.

## Append, don't rewrite

**Strongly bias toward appending new `RUN` blocks rather than editing existing ones.** Docker caches each layer by the literal text of its instruction. If you edit an earlier line, every layer after it rebuilds from scratch.

Concretely:

- **Good** — adding a new package next session: append a *new* `RUN apt-get install -y --no-install-recommends newpkg && rm -rf /var/lib/apt/lists/*` block at the bottom.
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

If the project uses Nix, install it once at the bottom of the overlay and never re-run that block. Subsequent Nix package additions belong in a `flake.nix` / `default.nix` checked into the repo, not in the overlay:

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

## Workflow

1. You've just installed something inside the running container and confirmed it works.
2. Read `.claude-container-overlay` if it exists. If it doesn't, create it.
3. **Append** a new `RUN` block (or `ENV`/`COPY` line) to the end. Date the comment so future-you can prune dead entries.
4. Tell the user briefly: "Persisted `<thing>` to `.claude-container-overlay` — the next `claude-container` launch will rebuild the image with it baked in (~30s on first run, cached after)."
5. Don't run `docker build` yourself. The launcher handles it on next invocation.

## What the launcher does

When `claude-container` starts in a workspace containing `.claude-container-overlay`:

1. Hashes the overlay file plus the base image tag.
2. Looks for a local image tagged `claude-container-overlay:<hash>`.
3. If it exists, uses it. If not, builds it: `FROM <base-image>` followed by the overlay's contents.
4. Runs the container as usual against that image.

Because the tag is content-addressed, switching branches that have different overlays just switches images — no rebuild needed if you've used that overlay before.

## Things that won't work

- `USER` directives in the overlay — the base image's entrypoint manages users dynamically based on `USER_UID`/`USER_GID`. Setting `USER` in the overlay breaks the UID-mapping flow.
- `ENTRYPOINT` / `CMD` — same reason; the base image's entrypoint must run.
- `WORKDIR` other than `/workspace` — `/workspace` is the bind mount point.
- Anything that requires the workspace files to be present at *build* time. The workspace is mounted at *run* time. If you need files inside the image, copy them into a stable subdirectory in the overlay context, but prefer not to — bind mounts are simpler.
