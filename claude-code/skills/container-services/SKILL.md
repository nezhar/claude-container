---
name: container-services
description: Expose an HTTP dashboard, dev server, or API running inside the claude-container to the user's browser — by name, with no port collisions and no restart. Use whenever you start a server the user should open, whenever the user asks to reach an in-container port from the host, and whenever you see "ports" entries in .claude-container-overlay/overlay.json that could migrate to named services. Declare {"services": {"<name>": <port>}} in overlay.json and hand the user a URL like http://<name>.$CLAUDE_SERVICE_INSTANCE.claude.localhost/ — it works immediately.
---

# claude-container named services

Every claude-container instance publishes a single in-container mux on an
**ephemeral** host port, so any number of containers (one per git worktree is
the common case) can run at once with zero port collisions. In-container
services are tunneled through it **by name**: a host-side router
(`claude-container-router`) turns names into stable URLs. You declare names;
nobody ever picks host ports.

## The one thing to do

You started a server inside the container (say a dashboard on port 8099) and
the user should be able to open it. Add one entry to
`.claude-container-overlay/overlay.json` at the workspace root:

```json
{
  "services": {"dashboard": 8099}
}
```

Then tell the user the URL:

```
http://dashboard.$CLAUDE_SERVICE_INSTANCE.claude.localhost/
```

That's it. **No container restart, no launcher restart** — service names are
resolved by re-reading `overlay.json` on every connection, so the URL works the
moment you save the file (as long as your server is running).

Rules:

- The port is the one your server listens on **inside the container**.
  Listening on `localhost` is fine — the mux connects from localhost.
- Service names: lowercase letters, digits, `-`/`_`, starting with a
  letter or digit (`^[a-z0-9][a-z0-9_-]*$`).
- Keep any existing keys in `overlay.json` (`ports`, other services) intact —
  read-modify-write the JSON.

## The instance name

`$CLAUDE_SERVICE_INSTANCE` is set in the container's environment by the
launcher — use it verbatim when constructing URLs. It is the host-side
workspace directory's basename (sanitized; a short hash is appended when two
different workspaces share a basename), which you **cannot** derive from
`/workspace`, so don't guess: read the variable. If it's unset (older
launcher), tell the user to run `claude-container --services` on the host,
which lists every instance and the exact working URLs.

## URL forms (for telling the user)

| Form | Notes |
|---|---|
| `http://<service>.<instance>.claude.localhost/` | Preferred. Portless form works when the router holds port 80: automatic on macOS, needs `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80` on Linux. |
| `http://<service>.<instance>.claude.localhost:8484/` | Always-works fallback (the router's primary port). |
| `http://127.0.0.1:8484/` | Index page listing every instance and service. |
| `http://<service>.<instance>.claude/` | Only if the user wired up the router's DNS server (see README); don't lead with this. |

Give the user the portless form first, with the `:8484` variant as fallback.
For a **non-HTTP TCP** service (database, gRPC without a UI, etc.), declare it
the same way and tell the user to run this on the host to get a raw local
port:

```bash
claude-container --service-port <instance>/<service>
```

## Verifying from inside the container

You cannot open the router's URLs from inside the container (they route on the
host's loopback). Verify the two halves you *can* reach instead:

1. Your server answers locally: `curl -s http://localhost:8099/`
2. The mux resolves the name (it listens on `localhost:7999` in-container and
   speaks a one-line preamble protocol):

   ```bash
   printf 'dashboard\n' | timeout 2 python3 -c '
   import socket, sys
   s = socket.create_connection(("localhost", 7999))
   s.sendall(sys.stdin.buffer.read())
   print(s.makefile("rb").readline().decode().strip())'
   ```

   `OK 8099` means the name resolves and the service is reachable — the URL
   will work on the host. `ERR unknown service ...` means the overlay.json
   entry is missing or misnamed; `ERR` with a connection error means your
   server isn't listening.

If both pass, state the URL confidently; don't hedge.

## Migrating from "ports" to named services

Older overlays forward fixed host ports:

```json
{
  "ports": ["8099:8099", "127.0.0.1:3000:3000", "9000:9000/udp"]
}
```

Fixed mappings have two problems named services don't: they collide the moment
a second container (another worktree) claims the same host port, and adding one
only takes effect at the **next launch**. Migrate each entry that is an HTTP(ish)
service the user opens in a browser or with curl:

1. Identify what each mapping serves (check the repo's configs, running
   processes, or ask the user if it's unclear — don't guess names).
2. Move it to `services`, keyed by a descriptive name, keeping only the
   **container** port (the part after the last `:`).
3. Keep a `ports` entry only when it genuinely needs a fixed host port:
   - **UDP** (`/udp` suffix) — the mux is TCP-only.
   - Something **outside the machine** connects in on a well-known port
     (a device on the LAN, a webhook target, a hardcoded callback).
   - A config file or tool **hardcodes** the host port and can't be pointed
     at a URL or looked-up port.

Before/after for the example above (the dashboard and dev server migrate, the
UDP listener stays):

```json
{
  "ports": ["9000:9000/udp"],
  "services": {"dashboard": 8099, "devserver": 3000}
}
```

Tell the user the new URLs and note that the old `-p` forwards disappear at the
next launch (removing a `ports` entry, like adding one, only applies then —
the migrated services themselves work immediately).

If the overlay is still the **legacy single-file** form
(`.claude-container-overlay` as a file with `# claude-container:port ...`
comments), migrate it to the directory form first — the `container-overlay`
skill describes that — then apply the steps above.

## When NOT to use this

- **UDP or fixed-host-port needs** — keep using `ports` (see above).
- **Host-to-host tooling** — if the thing the user wants to reach runs on the
  host, none of this applies.
- Don't add a service entry for one-shot debugging servers you'll kill in a
  minute anyway, unless the user asked to see it — declared names linger in
  `overlay.json` (they're harmless but noisy; clean up entries whose servers
  are gone for good).
