---
name: container-tmux
description: How to drive the tmux session that wraps Claude inside claude-container. Use whenever you need to run a long-lived or interactive command in a separate shell (dev server, REPL, log tail, watcher), give the user a shell they can type into, or read back output from a command you started elsewhere. Only applies when the container was launched with `claude-container --tmux`; the canonical session is named `claude`.
---

# claude-container tmux session

When the container is started with `claude-container --tmux`, Claude Code runs
**inside a tmux session** so that you and the user share one multi-window
terminal inside the container. This lets the user open extra shells and run
commands without going through you, and lets you start, drive, and observe
long-lived or interactive processes in their own windows.

If the container was *not* started with `--tmux`, none of this applies — `tmux`
won't have a server running and `tmux` commands will fail. A quick
`tmux has-session -t claude 2>/dev/null && echo yes` tells you whether you're in
a tmux-enabled container.

## The canonical session

- **Session name: `claude`** (stable — always target this name).
- Claude itself runs in window `agent` (window index `0`) of that session.
- The host's `~/.tmux.conf` is mounted in (when present), so the user's keybinds,
  prefix, and status line are the ones they're used to.

Because the name is fixed, you can address any window deterministically as
`claude:<window>` (e.g. `claude:1`) or a specific pane as `claude:<window>.<pane>`.

Don't name a window `claude` (or anything starting with `claude`): tmux resolves a
`-t claude` target to a matching **window** before the session, so a window called
`claude` would shadow the session and break `tmux new-window -t claude`. That's why
the first window is `agent`, not `claude`.

## What the user can do without you

The user is attached to the `claude` session in their terminal. With their normal
tmux prefix they can open a new window (default `prefix c`), switch windows
(`prefix n` / `prefix p` / `prefix <number>`), split panes, and type commands
straight into the container — no need to ask you. Don't be surprised if new
windows appear that you didn't create.

## Driving windows yourself

You manage windows with ordinary `tmux` commands from your Bash tool. They talk to
the same tmux server because you're running inside the session.

Create a window and start a long-lived process in it:

```bash
tmux new-window -t claude -n devserver
tmux send-keys -t claude:devserver 'pnpm dev' Enter
```

Send input to an existing window (note the literal `Enter` to submit):

```bash
tmux send-keys -t claude:devserver 'rs' Enter      # type 'rs' and press Enter
tmux send-keys -t claude:devserver C-c             # send Ctrl-C
```

Read back what a window has printed (essential — `send-keys` gives no output):

```bash
tmux capture-pane -t claude:devserver -p           # current screen
tmux capture-pane -t claude:devserver -p -S -200   # last 200 lines of scrollback
```

List and inspect windows:

```bash
tmux list-windows -t claude
tmux list-panes -t claude -F '#{window_index}.#{pane_index} #{pane_current_command}'
```

Clean up a window when its process is done:

```bash
tmux kill-window -t claude:devserver
```

## Patterns

- **Long-running server / watcher**: start it in its own named window with
  `new-window` + `send-keys`, then `capture-pane` to check it came up. Don't run
  these as blocking foreground Bash calls — put them in a window so they keep
  running and you stay free.
- **Interactive REPL / TUI**: launch it in a window, drive it with `send-keys`,
  observe with `capture-pane`. This is the way to script tools that expect a TTY.
- **Reading output**: `send-keys` is fire-and-forget. Always follow up with
  `capture-pane -p` to see the result; give the command a moment if it's slow.
- **Naming**: pass `-n <name>` to `new-window` and address windows by name. Names
  are stabler than indices once the user starts opening their own windows.

## Gotchas

- `send-keys` types characters; it does **not** press Enter unless you append the
  `Enter` key name. Likewise use key names like `C-c`, `C-d`, `Tab`, `Escape`.
- Quote literal strings you send so the shell here doesn't expand them before tmux
  sees them.
- Don't kill the `agent` window (`claude:0`) — that's where Claude (you) runs;
  killing it tears down your own process and the container exits.
- Output only appears in `capture-pane` after the process writes it. For slow
  commands, capture again after a short wait rather than assuming no output.
