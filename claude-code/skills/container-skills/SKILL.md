---
name: container-skills
description: Propose a reusable Claude Code skill from inside the claude-container so it persists across sessions and can be shared with the user's other projects. Use when you've worked out a non-obvious, reusable workflow worth teaching future sessions — write it to .claude-container-overlay/skills/<name>/SKILL.md at the workspace root. The launcher deploys workspace skills at the next launch, and the user can promote them to every project with `claude-container --skills-adopt`.
---

# Proposing skills from inside the container

The `claude-container` launcher gives skills a promotion path from a single
workspace out to every claude-container project on the user's machine. You (the
agent inside the container) create the first step; the user controls the rest.

## How skills flow

1. **Workspace skills** — `<workspace>/.claude-container-overlay/skills/<name>/SKILL.md`.
   This is where you propose. The directory lives in the workspace, so it can be
   committed to the repo. At every launch, the launcher deploys all workspace
   skills into the live skills directory for this project.
2. **User-wide skills** — `~/.config/claude-container/user-skills/` on the host.
   The *user* promotes a workspace skill there by running
   `claude-container --skills-adopt <name>` on the host. Adopted skills are
   offered to every claude-container project.
3. **Per-project choices** — when another project's launch sees a user-wide
   skill it hasn't decided on, the launcher prompts the user once
   (yes / no / ask later). The answer is sticky per project.

You can only write tier 1. Tiers 2 and 3 are host-side `claude-container`
commands — suggest them to the user; do not try to run them in here.

## When to propose a skill

Propose one when you've worked out something **reusable and non-obvious** that a
future session would otherwise have to rediscover: a multi-step debugging
workflow, the correct way to drive a fussy tool, a project-independent procedure
you had to piece together from several sources.

Do **not** propose a skill for:

- Project-specific facts or conventions — those belong in `CLAUDE.md`.
- Anything a single `README` line or code comment covers.
- Things Claude already knows how to do without instructions.
- Container tooling persistence — that's the `container-overlay` skill's job
  (Dockerfile fragment), not a skill.

## How to propose

1. Pick a name: lowercase letters, digits, and hyphens only (e.g.
   `bazel-flaky-test-triage`). The names `container-overlay`, `container-tmux`,
   and `container-skills` are reserved for image-bundled skills.
2. Create `.claude-container-overlay/skills/<name>/SKILL.md` at the workspace
   root:

   ```markdown
   ---
   name: bazel-flaky-test-triage
   description: Triage a flaky Bazel test — when to use this and what it does, in one or two sentences. This line is what decides whether the skill gets loaded, so make the trigger conditions concrete.
   ---

   # Bazel flaky test triage

   Step-by-step instructions written for a future session with no memory of
   this conversation...
   ```

   Supporting files (scripts, templates) can sit next to `SKILL.md` in the same
   directory; the whole directory is deployed.
3. Tell the user briefly: the skill is proposed in
   `.claude-container-overlay/skills/<name>/` and becomes active at the next
   `claude-container` launch. If it looks useful beyond this project, suggest
   they run `claude-container --skills-adopt <name>` on the host to share it
   with every project.

Don't copy the skill anywhere else (in particular not into
`$CLAUDE_CONFIG_DIR/skills` directly) — the launcher owns deployment and cleans
up based on a manifest; hand-placed copies escape that lifecycle and linger for
every project.

## Updating a proposal

Edit the files under `.claude-container-overlay/skills/<name>/` in place; the
launcher re-deploys them on every launch. If the skill was already adopted
user-wide, the workspace copy wins in *this* project, but the shared copy stays
stale — tell the user to re-run `claude-container --skills-adopt <name>` to
refresh it everywhere.

## The user's management commands (host-side, for reference)

| Command | Effect |
|---|---|
| `claude-container --skills` | List skills and this project's choices |
| `claude-container --skills-adopt <name>` | Promote a workspace skill user-wide |
| `claude-container --skills-accept <name>` | Include a user-wide skill in this project |
| `claude-container --skills-reject <name>` | Exclude a user-wide skill from this project |
| `claude-container --skills-reset` | Forget this project's choices (re-prompts) |
| `claude-container --skills-drop <name>` | Remove a skill from the user-wide set |
