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
| `wait_for` | no | `host:port` — wait for TCP connection before running command |

### Parameterization

Use standard shell variable expansion in commands:

```yaml
command: ./run.sh --env=${APP_ENV:-development}
```

Then override at invocation:

```bash
APP_ENV=production mxup up my-project
```

## Commands

| Command | Description |
|---------|-------------|
| `mxup up [name]` | Reconcile session to match config (default when no subcommand) |
| `mxup status [name]` | Show per-window status with recent output |
| `mxup down [name]` | Kill the session |
| `mxup restart [name:]<w1,w2,...>` | Restart specific window(s) (comma-separated) |
| `mxup restart [name]` | Restart all windows in the session |

### Flags

| Flag | Description |
|------|-------------|
| `-f path` | Use a specific config file |
| `--dry-run` | Preview changes without applying (for `up` and `restart`) |
| `--lines N` | Number of output lines to show per window (for `status`, default 15) |

## Reconciliation

`mxup up` compares the declared config against the running tmux session:

- **Missing windows** → created and command started
- **Extra windows** → killed (with warning)
- **Idle/crashed windows** (shell prompt visible) → command re-sent
- **Healthy running windows** → left untouched

## License

MIT
