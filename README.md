# mxup

Declarative tmux session manager with reconciliation.

Run `mxup up` any time — it creates what's missing, restarts what crashed, removes what's not declared, and leaves healthy processes alone.

## Install

Requires tmux and Ruby (stdlib only, no gems).

```bash
git clone <repo-url> ~/IdeaProjects/mxup
ln -sf ~/IdeaProjects/mxup/bin/mxup ~/.local/bin/mxup
```

Make sure `~/.local/bin` is on your `PATH`.

## Quick start

```bash
# Create a config
mkdir -p ~/.config/mxup
cp ~/IdeaProjects/mxup/examples/air-dev.yml ~/.config/mxup/

# Bring the session up (reconcile)
mxup up air-dev

# Check what's running
mxup status air-dev

# Restart specific windows
mxup restart air-dev:air-backend
mxup restart air-dev:air-backend,agent-spawner

# Restart all windows
mxup restart air-dev

# Tear everything down
mxup down air-dev
```

## Config format

Configs live in `~/.config/mxup/<name>.yml` or can be passed via `-f path`.

```yaml
session: my-project

# Shell snippet run in every window before the command
setup: |
  direnv allow . 2>/dev/null
  eval "$(direnv export zsh 2>/dev/null)"

windows:
  database:
    root: ~/projects/my-app
    command: docker compose up postgres redis

  backend:
    root: ~/projects/my-app/backend
    wait_for: localhost:5432
    env:
      DATABASE_URL: postgres://localhost/myapp_dev
    command: ./start-server.sh

  frontend:
    root: ~/projects/my-app/frontend
    command: npm run dev

  shell:
    root: ~/projects/my-app
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `session` | yes | tmux session name |
| `setup` | no | Shell snippet prepended to every window's command |
| `windows` | yes | Ordered map of window definitions |

Per window:

| Field | Required | Description |
|-------|----------|-------------|
| `root` | yes | Working directory (supports `~`) |
| `command` | no | Command to run. Omit for an interactive shell. |
| `env` | no | Map of environment variables to export |
| `wait_for` | no | Readiness check to pass before running command (see below) |

### Wait-for checks

`wait_for` blocks a window's command until a readiness condition is met.

**Shorthand** — TCP check (backward compatible):

```yaml
wait_for: localhost:5432
```

**Expanded form** with explicit check type:

```yaml
# TCP port open
wait_for:
  tcp: localhost:5432

# HTTP 2xx response
wait_for:
  http: http://localhost:8080/health

# File or socket exists
wait_for:
  path: /tmp/app.sock

# Arbitrary script (exit 0 = ready)
wait_for:
  script: pg_isready -h localhost -p 5432
  label: postgres          # shown in wait/ready messages
```

All forms support optional `timeout` (seconds, default: unlimited) and `interval` (seconds between retries, default: 2):

```yaml
wait_for:
  tcp: localhost:5432
  timeout: 60
  interval: 5
```

| Option | Default | Description |
|--------|---------|-------------|
| `timeout` | unlimited | Max seconds to wait before giving up |
| `interval` | 2 | Seconds between retry attempts |
| `label` | target value | Display name in wait/ready messages |

### Parameterization

Use standard shell variable expansion in commands:

```yaml
command: ./run.sh --env=${APP_ENV:-development}
```

Then override at invocation:

```bash
APP_ENV=production mxup up my-project
```

### Layouts

Define multiple named layouts to control how windows are grouped as tmux panes:

```yaml
layouts:
  full:
    services:
      panes: [database, backend]
      split: even-horizontal
    frontend:
      panes: [frontend]

  compact:
    all:
      panes: [database, backend, frontend]
      split: tiled

  flat: {}
```

Each layout is a map of **group names** to group definitions. Windows in a group share a single tmux window as split panes. Windows not mentioned in any group remain standalone.

| Field | Required | Description |
|-------|----------|-------------|
| `layouts` | no | Map of named layout definitions |

Per group:

| Field | Required | Description |
|-------|----------|-------------|
| `panes` | yes | List of window names to group as panes |
| `split` | no | tmux layout: `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled` (default: `tiled`) |

The first layout is used by default. Override with `--layout`:

```bash
mxup up my-project --layout=compact
```

Switch layouts on a running session without killing processes:

```bash
mxup layout my-project compact
```

### Profiles

A single project often needs to run under different stacks — "local
everything", "staging backend with local frontend", etc. Profiles express
those variants as a set of overrides on top of a shared base. Only one
profile of a given config may be live at a time; `mxup up` of a different
profile automatically tears the current one down first.

```yaml
session: my-project

windows:
  backend:
    root: ~/projects/my-app/backend
    command: ./start-server.sh
    env:
      DATABASE_URL: postgres://localhost/myapp_dev

  frontend:
    root: ~/projects/my-app/frontend
    command: npm run dev

profiles:
  local: {}                      # uses the base as-is

  staging:
    windows:
      backend:
        command: ./connect-staging.sh
        env:
          DATABASE_URL: postgres://staging-db/myapp
```

Pick a profile with `--profile` (short: `-p`):

```bash
mxup up my-project --profile=local
mxup up my-project -p staging     # tears down 'local' first
mxup status my-project            # shows "profile: staging" in the header
```

| Field | Required | Description |
|-------|----------|-------------|
| `profiles` | no | Map of profile name → override block |
| `default_profile` | no | Profile to use when `--profile` is omitted (defaults to the first declared) |

**Override semantics**: the active profile's `setup`, `windows`, and
`layouts` override the base. Window overrides are merged per-key (so you
can tweak just `command` or `env` without redeclaring `root`). `env` maps
are themselves merged — keys not in the profile are inherited from the
base. A profile may not override `session`; profiles of the same group
must share one tmux session.

**Dropping windows**: to exclude a base window from a profile, map it to
`~` (YAML null):

```yaml
profiles:
  minimal:
    windows:
      dev-kit: ~         # don't start dev-kit under the `minimal` profile
      scratch: ~
```

Any layout groups that reference a dropped window are automatically
pruned — entries are stripped from `panes:` lists, and a group that ends
up empty is removed from its layout.

**Switching**: if the tmux session is already running under a different
profile, `mxup up` for a new profile runs `down` first (including the
graceful-stop dance), then brings the new profile up from a clean slate.
`mxup status` always shows the currently live profile in its header.

## Commands

| Command | Description |
|---------|-------------|
| `mxup up [name]` | Reconcile session to match config (default when no subcommand) |
| `mxup status [name]` | Show per-window status with recent output |
| `mxup down [name]` | Kill the session |
| `mxup restart [name:]<w1,w2,...>` | Restart specific window(s) (comma-separated) |
| `mxup restart [name]` | Restart all windows in the session |
| `mxup layout [name]` | Show available layouts and which is active |
| `mxup layout [name] <layout>` | Switch to a different layout (preserves running processes) |
| `mxup target [name:]<window>` | Print the tmux target (`session:window.pane`) for a logical window |
| `mxup target [name]` | Print targets for every declared window (tab-separated) |
| `mxup exec -t [name:]<window> "<cmd>"` | Run `<cmd>` in a pane, wait for completion, print output, exit with its status |

### Flags

| Flag | Description |
|------|-------------|
| `-f path` | Use a specific config file |
| `--dry-run` | Preview changes without applying (for `up`, `restart`, `exec`) |
| `--lines N` | Output lines to show (for `status` default 15, for `exec` default 50) |
| `--layout NAME` | Layout to use (for `up`) |
| `-p`, `--profile NAME` | Profile to use; auto-teardowns a live session running under a different profile (for `up`, `status`, `restart`) |
| `-t TARGET` | Pane target (for `exec`); accepts `name:window`, `window`, or `window.pane` |
| `--timeout N` | Max seconds to wait for the command (for `exec`; exit 124 on timeout) |
| `--force` | Send the command even if the pane is busy with another process (for `exec`) |
| `-q`, `--quiet` | Don't print captured output (for `exec`) |

### Running one-off commands in a pane (`mxup exec`)

`mxup exec` is a shortcut for the common "send a command to a tmux pane, wait
for it to finish, and show the output" loop. It handles the three annoying
parts for you:

1. **Resolving logical names to real tmux targets** — `air-backend` may actually
   live as pane `services.1`; `mxup exec -t air-dev:air-backend` figures that
   out via the active layout.
2. **Waiting for the command to finish** — uses `tmux wait-for` with a unique
   marker under the hood, so `exec` blocks until the command actually exits.
3. **Capturing output and exit status** — prints the last `--lines N` lines of
   the pane and exits with the command's own exit code.

So instead of the verbose recipe:

```bash
MARKER="fulltest-$(date +%s%N)"
tmux send-keys -t air-dev:scratch \
  "./gradlew test 2>&1 | tail -n 30; echo FULLTEST_EXIT=\$?; tmux wait-for -S $MARKER" Enter \
  && tmux wait-for $MARKER
tmux capture-pane -t air-dev:scratch -p -S -50
```

you write:

```bash
mxup exec -t air-dev:scratch "./gradlew test 2>&1 | tail -n 30"
echo "exit: $?"
```

The user command is wrapped in a subshell, so `exit`, `set -e`, or a failing
command won't kill the pane's interactive shell. By default `exec` refuses to
send to a pane that's currently running a non-shell process — pass `--force`
to override. Use `--timeout N` to avoid hanging indefinitely on a runaway
command (exits 124 on timeout).

## Reconciliation

`mxup up` compares the declared config against the running tmux session:

- **Missing windows** → created and command started
- **Extra windows** → killed (with warning)
- **Idle/crashed windows** (shell prompt visible) → command re-sent
- **Healthy running windows** → left untouched
- **Layout changed** → panes rearranged without killing processes

## License

MIT
