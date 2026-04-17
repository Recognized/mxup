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

### Flags

| Flag | Description |
|------|-------------|
| `-f path` | Use a specific config file |
| `--dry-run` | Preview changes without applying (for `up` and `restart`) |
| `--lines N` | Number of output lines to show per window (for `status`, default 15) |
| `--layout NAME` | Layout to use (for `up`) |

## Reconciliation

`mxup up` compares the declared config against the running tmux session:

- **Missing windows** → created and command started
- **Extra windows** → killed (with warning)
- **Idle/crashed windows** (shell prompt visible) → command re-sent
- **Healthy running windows** → left untouched
- **Layout changed** → panes rearranged without killing processes

## License

MIT
