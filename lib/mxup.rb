# frozen_string_literal: true

# Declarative tmux session manager with reconciliation.
#
# Public entry points:
#   Mxup::CLI.new.run(argv)     — command-line dispatch
#   Mxup::Config.new(path)      — parse a YAML config
#   Mxup::Runner.new(config)    — programmatic API (up/down/status/...)
#
# Internals are organised into focused modules under lib/mxup/:
#   Config / Window / PaneGroup / WaitSpec   — pure data
#   Tmux                                     — thin tmux(1) wrapper
#   Launcher                                 — per-window launcher scripts
#   PaneResolver                             — logical-name → tmux target
#   Reconciler                               — `up` / `reconcile` orchestration
#   LayoutManager                            — layout switching (flatten + regroup)
#   StatusView                               — `status` rendering
#   ExecRunner                               — `exec` with marker + timeout
#   GracefulStop                             — cooperative SIGINT-then-wait
#   ProcessProbe                             — pane → real leaf process info
#   Runner                                   — facade delegating to the above
#   CLI                                      — argv parsing + command dispatch

module Mxup
  VERSION      = '0.2.0'
  CONFIG_DIR   = File.expand_path('~/.config/mxup')
  RUNTIME_DIR  = File.expand_path('~/.local/share/mxup')
  SHELLS       = %w[zsh bash sh fish dash].freeze
end

require_relative 'mxup/config'
require_relative 'mxup/tmux'
require_relative 'mxup/launcher'
require_relative 'mxup/process_probe'
require_relative 'mxup/pane_resolver'
require_relative 'mxup/graceful_stop'
require_relative 'mxup/layout_manager'
require_relative 'mxup/reconciler'
require_relative 'mxup/status_view'
require_relative 'mxup/exec_runner'
require_relative 'mxup/runner'
require_relative 'mxup/cli'
