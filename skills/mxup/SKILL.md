---
name: mxup
description: Manage tmux sessions via mxup — a declarative tmux session manager. Use when the user mentions mxup, tmux panes/windows/sessions, or when running, restarting, or capturing output from commands in tmux panes started by mxup. Prefer `mxup exec` over raw `tmux send-keys` / `tmux wait-for` / `tmux capture-pane`. Also use when editing mxup config files (typically `~/.config/mxup/<name>.yml` or files matching `mxup*.yml`).
---

# mxup

**Declarative tmux session manager with reconciliation.** A YAML file describes windows, commands, and layouts. `mxup up` brings the live tmux session into agreement with it: creates missing, restarts crashed, removes undeclared, leaves healthy alone. Idempotent — re-running `up` is safe.

Configs live in `~/.config/mxup/<name>.yml` (or pass `-f <path>`).

## When to use this skill

Activate this skill whenever the agent needs to:

- Run a command inside a tmux pane that was started by `mxup` and capture its output.
- Restart a window after editing its config.
- Inspect pane status or recent output.
- Edit a user's `mxup` YAML config (respecting the rules in [Editing an mxup config](#editing-an-mxup-config) below).

When in doubt: if tmux panes are involved and `mxup` is available, prefer `mxup` over raw `tmux` commands.

## Running commands in panes — prefer `mxup exec`

Instead of the manual `tmux send-keys … tmux wait-for … tmux capture-pane` dance, use `mxup exec`. It resolves logical names, blocks until the command finishes, prints captured output, and exits with the command's real return code:

```bash
mxup exec -t my-proj:backend "./gradlew test 2>&1 | tail -n 30"
echo "exit: $?"
```

It refuses to target a pane running a non-shell process unless `--force` is passed. Use `--timeout N` to avoid hanging (exits `124` on timeout). Use `-q` to suppress the command echo.

## Command reference

```
mxup up [name]                     # reconcile (default when no subcommand)
mxup status [name]                 # per-window status + recent output
mxup down [name]                   # graceful stop + kill-session
mxup restart [name:]w1,w2          # restart specific windows
mxup restart [name]                # restart all windows
mxup layout [name] <layout>        # switch layout, preserves running PIDs
mxup target [name:]<window>        # print tmux target for a logical name
mxup exec -t <target> "<cmd>"      # run + wait + capture output + exit rc
```

Flags:

- `-f <path>` — explicit config path.
- `--dry-run` — preview without changes.
- `--layout NAME` — layout override for `up`.
- `-p` / `--profile NAME` — for `up` / `status` / `restart`; auto-tears down a live session running under a different profile.
- `--timeout N`, `--force`, `-q` — for `exec`.

## Editing an mxup config

See [reference.md](reference.md) for the full config shape. Key rules when editing a user's config:

- **Preserve window declaration order** — it drives pane/window order.
- A window without `command` is an interactive shell (useful for scratch panes).
- Changing `wait_for`, `env`, or `command` takes effect on the next `mxup restart <window>` or `mxup up` *after the pane goes idle* — `up` alone won't restart a still-running healthy process. After editing, remind the user to restart the affected window (or do it yourself when appropriate).

## Profiles

- Only one profile of a group may be live at a time.
- `mxup up -p X` while profile `Y` is running triggers a `down` of `Y` first.
- Profiles share the top-level `session` name; overriding `session` from a profile is an error.
- `mxup status` shows the active profile in the header.
