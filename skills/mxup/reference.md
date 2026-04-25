# mxup config reference

Full config shape for `~/.config/mxup/<name>.yml`. The skill's [SKILL.md](SKILL.md) covers the common editing rules; this file is the detailed field-by-field reference.

## Example

```yaml
session: my-proj
setup: |                            # optional; runs in every window before its command
  eval "$(direnv export bash)"
windows:
  db:
    root: ~/app
    command: docker compose up postgres
  backend:
    root: ~/app/backend
    wait_for: localhost:5432        # shorthand = tcp; also { http:, path:, script: }
    env: { DATABASE_URL: postgres://localhost/myapp_dev }
    command: ./start.sh
  shell:                            # no `command` → interactive shell
    root: ~/app

layouts:                            # optional; first is default, override with --layout
  full:
    services: { panes: [db, backend], split: even-horizontal }
  flat: {}                          # empty → all windows standalone

profiles:                           # optional; mutually-exclusive variants of the same session
  local: {}
  staging:                          # per-key overrides on the base windows/setup/layouts
    windows:
      backend:
        command: ./connect-staging.sh
        env: { DATABASE_URL: postgres://staging-db/myapp }   # merges into base env
      dev-kit: ~                    # null drops the window from this profile
```

## Top-level fields

| Field      | Required | Notes                                                            |
|------------|----------|------------------------------------------------------------------|
| `session`  | yes      | tmux session name. Profiles must not override this.              |
| `setup`    | no       | Shell snippet run in every window before its `command`.          |
| `windows`  | yes      | Map of logical window name → window spec. Order matters.         |
| `layouts`  | no       | Named layouts. The first defined layout is the default.          |
| `profiles` | no       | Named overrides on top of the base config.                       |

## Window fields

| Field      | Required | Notes                                                                                 |
|------------|----------|---------------------------------------------------------------------------------------|
| `root`     | yes      | Working directory. `~` is expanded.                                                   |
| `command`  | no       | Command to run. Omit for an interactive shell.                                        |
| `env`      | no       | Map merged on top of the inherited environment.                                        |
| `wait_for` | no       | Readiness check before starting the command. See below.                                |

### `wait_for` forms

- Shorthand string `host:port` — TCP check.
- Expanded object — `{ tcp: …, http: …, path: …, script: … }`, plus optional `timeout`, `interval`, `label`.

## Layout fields

A layout maps *group name* → `{ panes: [window, …], split: <tmux split-layout> }`. An empty layout (`{}`) flattens to one window per pane.

Common `split` values: `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`.

## Profile semantics

- Only one profile in a group may be live; `mxup up -p X` while `Y` is running triggers `down Y` first.
- Per-key overrides merge onto base windows/setup/layouts.
- `env` is merged (not replaced) on a per-window basis.
- Setting a window to `~` (null) drops it from that profile.
- Overriding the top-level `session` from a profile is an error.
