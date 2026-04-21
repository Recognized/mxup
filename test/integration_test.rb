#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration tests that drive a real tmux server.
#
# Design principles (learned the hard way from the flaky first iteration):
#
#   1. Each test gets its own uniquely named session. Nothing is shared
#      between tests, so parallelism and order-dependence are impossible.
#
#   2. No `sleep N` as a synchronization primitive — it's always a race.
#      Use `wait_until { ... }` with a generous deadline, which returns as
#      soon as the condition becomes true.
#
#   3. Teardown is bullet-proof: it always kills the session and always
#      removes the per-session launcher directory, even on assertion failure.
#
#   4. Tests are grouped into focused Minitest classes (one per command /
#      feature) for readable output.

require_relative 'test_helper'
require 'securerandom'

# ---------------------------------------------------------------------------
# Dedicated tmux server for the test suite
# ---------------------------------------------------------------------------
# The user's personal tmux config may set `default-shell` to an interactive
# shell whose rc files take seconds to load (zsh, oh-my-zsh, etc.). That
# makes send-keys racy and tests excruciatingly slow.
#
# Running tests on a private tmux server lets us:
#   * pick a fast, rc-free default-shell (/bin/bash works on most dev boxes)
#   * kill the whole server on teardown, so no session, pane or zombie
#     process can leak past the test run
#   * stay completely out of the user's attached tmux session
#
# The private server is selected via TMUX_TMPDIR — tmux uses it as the socket
# dir — which is transparently inherited by every subprocess we shell out to.

unless ENV['MXUP_SHARE_TMUX_SERVER']
  # CRITICAL: unset TMUX before doing anything. When tests run from inside a
  # tmux pane, TMUX points at the user's real server socket — and commands
  # like `tmux kill-server` honour it over TMUX_TMPDIR, which would murder
  # the user's workspace.
  ENV.delete('TMUX')
  ENV.delete('TMUX_PANE')

  # Use a short path: macOS limits unix socket paths to ~104 bytes, and the
  # default tmpdir (/var/folders/...) already eats most of that.
  ENV['TMUX_TMPDIR'] = Dir.mktmpdir('mxup-', '/tmp')

  # Configure the private server via a preload file. Empty tmux servers
  # exit the moment the first command returns, so setting options with
  # `set-option -g` AFTER `start-server` is a race we lose every time.
  # `-f <config>` is loaded when the server spins up, so the options are
  # live before any session is created.
  tmux_conf = File.join(ENV['TMUX_TMPDIR'], 'tmux.conf')
  File.write(tmux_conf, <<~CONF)
    # /bin/bash on this machine has no .bashrc so login is <5ms. /bin/zsh's
    # interactive init can take 45+ seconds which makes send-keys racy.
    set -g default-shell /bin/bash

    # Without an attached client, window size defaults to whatever the
    # daemon feels like — 80x24 is fine, but subsequent split-pane calls
    # inside main-vertical layouts can end up as narrow as 1 column. Pin a
    # generous size so launcher-script paths never wrap into oblivion.
    set -g default-size 200x50

    # Keep status off; no client will see it anyway, and it steals a line.
    set -g status off
  CONF

  # Spin the server up with `-f <config>` so our options are live before
  # any test session is created. A holder session is required because an
  # empty tmux server exits the instant its last session closes.
  system("tmux -f #{tmux_conf} new-session -d -s __holder -x 200 -y 50 'sleep 86400' 2>/dev/null")

  Minitest.after_run do
    system('tmux kill-server 2>/dev/null')
    FileUtils.rm_rf(ENV['TMUX_TMPDIR']) if ENV['TMUX_TMPDIR']
  end
end

# ---------------------------------------------------------------------------
# Shared integration helpers
# ---------------------------------------------------------------------------

module IntegrationHelpers
  include TestHelpers::TmpDir

  SESSION_PREFIX = 'mxup-it'

  def setup
    super
    @session = "#{SESSION_PREFIX}-#{SecureRandom.hex(4)}"
  end

  def teardown
    kill_session(@session)
    cleanup_runtime_for(@session)
    super
  end

  # ---- session / runtime ---------------------------------------------------

  attr_reader :session

  def kill_session(name)
    system("tmux kill-session -t #{name} 2>/dev/null")
  end

  def cleanup_runtime_for(name)
    dir = File.join(Mxup::RUNTIME_DIR, name)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end

  # ---- config + runner construction ---------------------------------------

  # Write a YAML config that always uses the per-test session name and
  # return a ready-to-use [config, runner] pair. The YAML should omit the
  # top-level `session:` line; we prepend it automatically.
  def make_runner(yaml, dry_run: false, layout: nil)
    body = "session: #{@session}\n#{yaml}"
    config = Mxup::Config.new(write_yaml(body))
    [config, Mxup::Runner.new(config, dry_run: dry_run, layout: layout)]
  end

  # Convenience: returns the runner only, for tests that don't need the
  # config object directly.
  def runner_for(yaml, **opts)
    make_runner(yaml, **opts).last
  end

  # ---- tmux queries -------------------------------------------------------

  def window_names
    return [] unless Mxup::Tmux.has_session?(@session)
    Mxup::Tmux.list_windows(@session).sort_by { |w| w[:index] }.map { |w| w[:name] }
  end

  def panes_in(window_name)
    Mxup::Tmux.list_panes(@session)
      .select { |p| p[:name] == window_name }
      .sort_by { |p| p[:pane_index] }
  end

  def pane_fg(window_name, pane_index: 0)
    panes_in(window_name).find { |p| p[:pane_index] == pane_index }&.dig(:fg_cmd)
  end

  # ---- polling ------------------------------------------------------------

  # Poll a block for up to `timeout` seconds, returning the block's value as
  # soon as it becomes truthy, or raising with `message` on timeout.
  # Leave `message: nil` to return nil on timeout instead of raising.
  #
  # Interval defaults to 0.3s. Tighter intervals are counter-productive:
  # each poll spawns a tmux(1) client, which contends with the tmux server
  # for the same lock the panes' shells need to make progress. Polling too
  # aggressively literally starves the test shells.
  def wait_until(timeout: 10, interval: 0.3, message: nil)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      break if Time.now > deadline
      sleep interval
    end
    if message
      raise Minitest::Assertion,
            "Timed out after #{timeout}s waiting: #{message} " \
            "(panes: #{safe_pane_snapshot.inspect})"
    end
    nil
  end

  def wait_for_fg(window, expected, pane_index: 0, timeout: 10)
    wait_until(timeout: timeout,
               message: "pane #{window}.#{pane_index} fg == #{expected.inspect}") do
      pane_fg(window, pane_index: pane_index) == expected
    end
  end

  # Snapshot of panes for error diagnostics; swallow tmux errors so we can
  # always produce *some* output even if the session has vanished.
  def safe_pane_snapshot
    return [] unless Mxup::Tmux.has_session?(@session)
    Mxup::Tmux.list_panes(@session).map do |p|
      target = "#{p[:name]}.#{p[:pane_index]}"
      content = Mxup::Tmux.capture_pane(@session, target)
      { w: p[:name], i: p[:pane_index], fg: p[:fg_cmd],
        bytes: content.bytesize,
        dump: content.lines.last(8).map(&:rstrip).reject(&:empty?) }
    end
  rescue StandardError
    []
  end

  # ---- command shortcuts --------------------------------------------------

  # Run `runner.up` while swallowing the informational output. Returns the
  # captured [out, err] pair for tests that want to inspect it.
  def up!(runner)
    capture_io { runner.up }
  end

  def down!(runner)
    capture_io { runner.down }
  end

  def status!(runner, lines: 5)
    capture_io { runner.status(lines: lines) }
  end

  # exec terminates via exit(rc); wrap so callers get [out, err, status].
  def exec!(runner, *args, **kwargs)
    status = nil
    out, err = capture_io do
      begin
        runner.exec(*args, **kwargs)
      rescue SystemExit => e
        status = e.status
      end
    end
    [out, err, status]
  end
end

# ===========================================================================
# Fresh start — `mxup up` with no pre-existing session
# ===========================================================================

class FreshStartTest < Minitest::Test
  include IntegrationHelpers

  def test_creates_session_with_windows_and_starts_commands
    _, runner = make_runner(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
    YAML

    out, = up!(runner)

    assert Mxup::Tmux.has_session?(session), 'session should exist'
    assert_equal %w[alpha beta], window_names
    assert_includes out, 'alpha: created'
    assert_includes out, 'beta: created'

    wait_for_fg('alpha', 'sleep', timeout: 10)
    assert_equal 'sleep', pane_fg('alpha')
  end

  def test_windows_are_reordered_to_match_config
    runner = runner_for(<<~YAML)
      windows:
        first:  { root: /tmp, command: sleep 600 }
        second: { root: /tmp, command: sleep 600 }
        third:  { root: /tmp, command: sleep 600 }
    YAML

    # Create in *reverse* order out-of-band to simulate a drifted session.
    Mxup::Tmux.new_session(session, 'third', '/tmp')
    Mxup::Tmux.send_keys(session, 'third', 'sleep 600')
    Mxup::Tmux.new_window(session, 'second', '/tmp')
    Mxup::Tmux.send_keys(session, 'second', 'sleep 600')
    Mxup::Tmux.new_window(session, 'first', '/tmp')
    Mxup::Tmux.send_keys(session, 'first', 'sleep 600')

    up!(runner)
    assert_equal %w[first second third], window_names
  end
end

# ===========================================================================
# Reconciliation — `mxup up` against an existing session
# ===========================================================================

class ReconcileTest < Minitest::Test
  include IntegrationHelpers

  CONFIG = <<~YAML
    windows:
      w: { root: /tmp, command: sleep 600 }
  YAML

  def test_healthy_window_is_reported_as_running
    runner = runner_for(CONFIG)
    up!(runner)
    wait_for_fg('w', 'sleep')

    out, = up!(runner)
    assert_includes out, 'w: running (sleep) — ok'
  end

  def test_idle_window_is_restarted
    runner = runner_for(CONFIG)
    up!(runner)
    wait_for_fg('w', 'sleep')

    Mxup::Tmux.send_interrupt(session, 'w')
    wait_until(message: 'sleep pid to exit') { pane_fg('w') != 'sleep' }

    out, = up!(runner)
    assert_includes out, 'w: restarted (was idle)'
  end

  def test_missing_window_is_created
    runner = runner_for(<<~YAML)
      windows:
        keep:    { root: /tmp, command: sleep 600 }
        new_one: { root: /tmp, command: sleep 600 }
    YAML

    Mxup::Tmux.new_session(session, 'keep', '/tmp')
    Mxup::Tmux.send_keys(session, 'keep', 'sleep 600')

    out, = up!(runner)
    assert_includes out,  'new_one: created (was missing)'
    assert_includes window_names, 'new_one'
  end

  def test_extra_window_is_removed
    runner = runner_for(<<~YAML)
      windows:
        keep: { root: /tmp, command: sleep 600 }
    YAML

    Mxup::Tmux.new_session(session, 'keep', '/tmp')
    Mxup::Tmux.send_keys(session, 'keep', 'sleep 600')
    Mxup::Tmux.new_window(session, 'rogue', '/tmp')

    _, err = up!(runner)
    assert_includes err,  'rogue: not in config — removing'
    refute_includes window_names, 'rogue'
  end

  def test_idle_pane_in_group_is_restarted_without_touching_siblings
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML

    up!(runner)
    wait_for_fg('main', 'sleep', pane_index: 0)
    wait_for_fg('main', 'sleep', pane_index: 1)

    Mxup::Tmux.send_interrupt(session, Mxup::Tmux.pane_target('main', 0))
    wait_until(message: 'pane a to become idle') { pane_fg('main', pane_index: 0) != 'sleep' }

    out, = up!(runner)
    assert_includes out, 'a: restarted (was idle)'
    assert_includes out, 'b: running (sleep)'
  end
end

# ===========================================================================
# Down — session teardown
# ===========================================================================

class DownTest < Minitest::Test
  include IntegrationHelpers

  CONFIG = <<~YAML
    windows:
      w: { root: /tmp, command: sleep 600 }
  YAML

  def test_kills_session
    runner = runner_for(CONFIG)
    up!(runner)
    assert Mxup::Tmux.has_session?(session)

    down!(runner)
    refute Mxup::Tmux.has_session?(session)
  end

  def test_announces_graceful_stop
    runner = runner_for(CONFIG)
    up!(runner)
    wait_for_fg('w', 'sleep')

    out, = down!(runner)
    assert_includes out, 'Stopping session'
    refute Mxup::Tmux.has_session?(session)
  end

  def test_noop_when_no_session_running
    runner = runner_for(CONFIG)
    out, = down!(runner)
    assert_includes out, 'not running'
  end
end

# ===========================================================================
# Restart — selective / bulk window restart
# ===========================================================================

class RestartTest < Minitest::Test
  include IntegrationHelpers

  MULTI = <<~YAML
    windows:
      a: { root: /tmp, command: sleep 600 }
      b: { root: /tmp, command: sleep 600 }
      c: { root: /tmp, command: sleep 600 }
  YAML

  def test_restart_single_window_touches_only_that_window
    runner = runner_for(MULTI)
    up!(runner)
    wait_for_fg('a', 'sleep')
    wait_for_fg('b', 'sleep')

    out, = capture_io { runner.restart(['a']) }
    assert_includes out, 'a: restarted'
    refute_includes out, 'b:'
    refute_includes out, 'c:'
  end

  def test_restart_multiple_windows_via_comma_list
    runner = runner_for(MULTI)
    up!(runner)
    wait_for_fg('a', 'sleep')

    out, = capture_io { runner.restart(['a,c']) }
    assert_includes out, 'a: restarted'
    assert_includes out, 'c: restarted'
    refute_includes out, 'b:'
  end

  def test_restart_with_empty_arg_list_restarts_all
    runner = runner_for(MULTI)
    up!(runner)
    wait_for_fg('a', 'sleep')

    out, = capture_io { runner.restart([]) }
    assert_includes out, 'a: restarted'
    assert_includes out, 'b: restarted'
    assert_includes out, 'c: restarted'
  end

  def test_restart_targets_pane_in_group
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML

    up!(runner)
    wait_for_fg('main', 'sleep', pane_index: 0)
    wait_for_fg('main', 'sleep', pane_index: 1)

    out, = capture_io { runner.restart(['a']) }
    assert_includes out, 'a: restarted'
    refute_includes out, 'b:'
  end
end

# ===========================================================================
# Dry run — no tmux mutations
# ===========================================================================

class DryRunTest < Minitest::Test
  include IntegrationHelpers

  def test_up_does_not_create_session
    runner = runner_for(<<~YAML, dry_run: true)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    out, = up!(runner)
    refute Mxup::Tmux.has_session?(session)
    assert_includes out, '[dry-run]'
  end

  def test_up_on_drifted_session_does_not_modify
    runner = runner_for(<<~YAML, dry_run: true)
      windows:
        keep: { root: /tmp, command: sleep 600 }
    YAML

    Mxup::Tmux.new_session(session, 'keep', '/tmp')
    Mxup::Tmux.send_keys(session, 'keep', 'sleep 600')
    Mxup::Tmux.new_window(session, 'extra', '/tmp')

    up!(runner)
    assert_includes window_names, 'extra',
                    'extra window should survive a dry-run reconcile'
  end

  def test_exec_does_not_block_on_wait_marker
    # Need a real session so exec passes the "is running" gate; the dry-run
    # is on a *second* runner against the same session. If exec weren't
    # dry-run-aware, it would block forever waiting for the marker.
    real  = runner_for(<<~YAML)
      windows:
        scratch: { root: /tmp }
    YAML
    up!(real)

    dry = runner_for(<<~YAML, dry_run: true)
      windows:
        scratch: { root: /tmp }
    YAML
    out, = capture_io { dry.exec('scratch', 'sleep 30') }
    assert_includes out, '[dry-run]'
  end
end

# ===========================================================================
# Status — rendering
# ===========================================================================

class StatusTest < Minitest::Test
  include IntegrationHelpers

  def test_shows_session_name_windows_and_recent_output
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML
    up!(runner)
    wait_for_fg('w', 'sleep', timeout: 10)

    out, = status!(runner)
    assert_includes out, "SESSION: #{session}"
    assert_includes out, '[0] w'
    assert_includes out, 'sleep'
  end

  def test_reports_when_session_not_running
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp }
    YAML

    out, = status!(runner)
    assert_includes out, 'NOT RUNNING'
  end

  def test_flags_missing_window
    runner = runner_for(<<~YAML)
      windows:
        exists: { root: /tmp, command: sleep 600 }
        gone:   { root: /tmp, command: sleep 600 }
    YAML

    Mxup::Tmux.new_session(session, 'exists', '/tmp')
    Mxup::Tmux.send_keys(session, 'exists', 'sleep 600')

    out, = status!(runner)
    assert_includes out, 'gone'
    assert_includes out, 'MISSING'
  end

  def test_flags_extra_window
    runner = runner_for(<<~YAML)
      windows:
        declared: { root: /tmp, command: sleep 600 }
    YAML

    Mxup::Tmux.new_session(session, 'declared', '/tmp')
    Mxup::Tmux.send_keys(session, 'declared', 'sleep 600')
    Mxup::Tmux.new_window(session, 'undeclared', '/tmp')

    out, = status!(runner)
    assert_includes out, 'undeclared'
    assert_includes out, '[NOT IN CONFIG]'
  end

  def test_shows_active_layout_and_group_membership
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML
    up!(runner)
    wait_for_fg('main', 'sleep', pane_index: 0, timeout: 10)

    out, = status!(runner)
    assert_includes out, 'layout: full'
    assert_includes out, 'main'
    assert_includes out, 'a, b'
  end

  def test_prints_target_address_for_standalone_window
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML
    up!(runner)

    out, = status!(runner, lines: 2)
    assert_includes out, "target: #{session}:w"
  end

  def test_prints_target_address_for_each_grouped_pane
    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
      layouts:
        full:
          svc: { panes: [alpha, beta], split: even-horizontal }
    YAML
    up!(runner)

    out, = status!(runner, lines: 2)
    assert_includes out, "target: #{session}:svc.0"
    assert_includes out, "target: #{session}:svc.1"
    assert_match(/^\s*alpha:\s*$/, out)
    assert_match(/^\s*beta:\s*$/,  out)
  end

  def test_surfaces_content_that_scrolled_past_the_lines_window
    # Emit a marker, then pad the pane with blank lines to push the marker
    # past the requested status tail. Status should still find it via the
    # full-scrollback filter.
    Mxup::Tmux.new_session(session, 'w', '/tmp')
    Mxup::Tmux.send_keys(session, 'w', 'echo UNIQUE_MARKER_XYZ')
    wait_until(message: 'marker to appear') do
      Mxup::Tmux.capture_pane(session, 'w', lines: 200).include?('UNIQUE_MARKER_XYZ')
    end
    Mxup::Tmux.send_keys(session, 'w', "printf '\\n%.0s' {1..200}")

    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp }
    YAML

    out, = status!(runner, lines: 10)
    assert_includes out, 'UNIQUE_MARKER_XYZ'
  end
end

# ===========================================================================
# Layouts — up/reconcile with pane groups
# ===========================================================================

class LayoutUpTest < Minitest::Test
  include IntegrationHelpers

  def test_up_creates_pane_group_and_hides_source_windows
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
        c: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML
    up!(runner)

    names = window_names
    assert_includes names, 'main'
    assert_includes names, 'c'
    refute_includes names, 'a'
    refute_includes names, 'b'
    assert_equal 2, Mxup::Tmux.pane_count(session, 'main')
  end

  def test_up_sets_pane_titles_inside_group
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML
    up!(runner)

    panes = panes_in('main')
    assert_equal 'a', panes[0][:title]
    assert_equal 'b', panes[1][:title]
  end

  def test_three_pane_group_has_correct_titles_roots_and_commands
    # Each window has a distinct root so we can verify pane cwds match.
    dirs = 3.times.map { Dir.mktmpdir('mxup-pane-') }
    a, b, c = dirs

    runner = runner_for(<<~YAML)
      windows:
        a: { root: #{a}, command: sleep 600 }
        b: { root: #{b}, command: sleep 600 }
        c: { root: #{c}, command: sleep 600 }
      layouts:
        full:
          grp: { panes: [a, b, c], split: main-vertical }
    YAML
    up!(runner)

    # Wait for all three sleep commands to become the foreground process —
    # this is the very thing the old test flaked on.
    3.times { |i| wait_for_fg('grp', 'sleep', pane_index: i, timeout: 10) }

    panes = panes_in('grp')
    assert_equal 3, panes.size

    %w[a b c].each_with_index do |title, i|
      assert_equal title, panes[i][:title]
      assert_equal File.realpath(dirs[i]), File.realpath(panes[i][:cwd])
      assert_equal 'sleep', panes[i][:fg_cmd]
    end
  ensure
    FileUtils.rm_rf(dirs) if dirs
  end

  def test_active_layout_is_stored_in_tmux_environment
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a] }
    YAML
    up!(runner)

    assert_equal 'full', Mxup::Tmux.show_environment(session, 'MXUP_LAYOUT')
  end

  def test_layout_override_picks_alternate_layout
    runner = runner_for(<<~YAML, layout: 'flat')
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        grouped:
          main: { panes: [a, b] }
        flat: {}
    YAML
    up!(runner)

    names = window_names
    assert_includes names, 'a'
    assert_includes names, 'b'
    refute_includes names, 'main'
  end
end

# ===========================================================================
# Layout switching — preserve PIDs across regroupings
# ===========================================================================

class LayoutSwitchTest < Minitest::Test
  include IntegrationHelpers

  def test_switching_preserves_pane_pids
    config, grouped = make_runner(<<~YAML, layout: 'grouped')
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
        c: { root: /tmp, command: sleep 600 }
      layouts:
        grouped:
          main: { panes: [a, b], split: even-horizontal }
        flat: {}
    YAML
    up!(grouped)
    wait_for_fg('main', 'sleep', pane_index: 0, timeout: 10)
    wait_for_fg('main', 'sleep', pane_index: 1, timeout: 10)
    wait_for_fg('c',    'sleep', timeout: 10)

    pids_before = Mxup::Tmux.list_panes(session).map { |p| p[:pid] }.sort

    flat = Mxup::Runner.new(config, layout: 'flat')
    capture_io { flat.switch_layout('flat') }

    pids_after = Mxup::Tmux.list_panes(session).map { |p| p[:pid] }.sort
    assert_equal pids_before, pids_after, 'PIDs should survive layout switch'
    assert_equal %w[a b c].sort, window_names.sort
  end

  def test_switching_from_flat_to_grouped_regroups_panes
    config, flat = make_runner(<<~YAML, layout: 'flat')
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
        c: { root: /tmp, command: sleep 600 }
      layouts:
        flat: {}
        compact:
          all: { panes: [a, b, c], split: tiled }
    YAML
    up!(flat)
    3.times { |i| wait_for_fg(%w[a b c][i], 'sleep', timeout: 10) }

    compact = Mxup::Runner.new(config, layout: 'compact')
    capture_io { compact.switch_layout('compact') }

    assert_includes window_names, 'all'
    assert_equal 3, Mxup::Tmux.pane_count(session, 'all')
  end

  def test_switching_to_active_layout_is_a_noop
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a] }
    YAML
    up!(runner)

    out, = capture_io { runner.switch_layout('full') }
    assert_includes out, "Already using layout 'full'"
  end

  def test_show_layouts_prints_all_layouts_with_groups
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp }
        b: { root: /tmp }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
        flat: {}
    YAML

    out, = capture_io { runner.show_layouts }
    assert_includes out, 'full'
    assert_includes out, 'flat'
    assert_includes out, 'main=[a,b]'
    assert_includes out, 'all standalone'
  end

  def test_windows_follow_layout_declaration_order
    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
        c: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML
    up!(runner)

    assert_equal %w[main c], window_names
  end
end

# ===========================================================================
# Target resolution — `mxup target`
# ===========================================================================

class TargetTest < Minitest::Test
  include IntegrationHelpers

  def test_prints_bare_window_for_standalone
    runner = runner_for(<<~YAML)
      windows:
        solo: { root: /tmp, command: sleep 600 }
    YAML
    up!(runner)

    out, = capture_io { runner.target(['solo']) }
    assert_equal "#{session}:solo", out.strip
  end

  def test_prints_pane_address_inside_group
    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
        gamma: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          svc: { panes: [alpha, beta, gamma], split: tiled }
    YAML
    up!(runner)

    {
      'alpha' => "#{session}:svc.0",
      'beta'  => "#{session}:svc.1",
      'gamma' => "#{session}:svc.2"
    }.each do |name, expected|
      out, = capture_io { runner.target([name]) }
      assert_equal expected, out.strip
    end
  end

  def test_listing_all_windows_prints_tab_separated_table
    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
        solo:  { root: /tmp, command: sleep 600 }
      layouts:
        full:
          grp: { panes: [alpha, beta], split: even-horizontal }
    YAML
    up!(runner)

    out, = capture_io { runner.target([]) }
    lines = out.strip.split("\n")
    assert_equal 3, lines.size
    assert_equal ['alpha', "#{session}:grp.0"], lines[0].split("\t", 2)
    assert_equal ['beta',  "#{session}:grp.1"], lines[1].split("\t", 2)
    assert_equal ['solo',  "#{session}:solo"],  lines[2].split("\t", 2)
  end

  def test_unknown_window_aborts
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML
    up!(runner)

    assert_raises(SystemExit) { capture_io { runner.target(['does-not-exist']) } }
  end

  def test_aborts_when_session_not_running
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    assert_raises(SystemExit) { capture_io { runner.target([]) } }
  end
end

# ===========================================================================
# Exec — run command in target pane with capture
# ===========================================================================

class ExecTest < Minitest::Test
  include IntegrationHelpers

  def with_scratch_session
    runner = runner_for(<<~YAML)
      windows:
        scratch: { root: /tmp }
    YAML
    up!(runner)
    # Scratch window has no command; ensure the shell is ready to accept input.
    wait_until(message: 'scratch shell to be idle') do
      fg = pane_fg('scratch')
      Mxup::SHELLS.include?(fg)
    end
    runner
  end

  def test_runs_command_and_captures_stdout
    runner = with_scratch_session

    out, _err, status = exec!(runner, 'scratch', 'echo mxup-exec-marker-xyz')
    assert_equal 0, status
    assert_includes out, 'mxup-exec-marker-xyz'
  end

  def test_propagates_non_zero_exit_code
    runner = with_scratch_session

    _out, _err, status = exec!(runner, 'scratch', 'exit 7')
    assert_equal 7, status
  end

  def test_accepts_session_prefixed_target
    runner = with_scratch_session

    out, _err, status = exec!(runner, "#{session}:scratch", 'echo via-prefixed-target')
    assert_equal 0, status
    assert_includes out, 'via-prefixed-target'
  end

  def test_rejects_mismatched_session_prefix
    runner = with_scratch_session

    assert_raises(SystemExit) do
      capture_io { runner.exec('other-session:scratch', 'echo nope') }
    end
  end

  def test_resolves_logical_name_inside_pane_group
    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp }
        beta:  { root: /tmp }
      layouts:
        full:
          grp: { panes: [alpha, beta], split: even-horizontal }
    YAML
    up!(runner)
    wait_until(message: 'beta shell to be idle') do
      Mxup::SHELLS.include?(pane_fg('grp', pane_index: 1))
    end

    out, _err, status = exec!(runner, 'beta', 'echo output-from-beta-pane')
    assert_equal 0, status
    assert_includes out, 'output-from-beta-pane'
  end

  def test_rejects_busy_pane_without_force
    runner = runner_for(<<~YAML)
      windows:
        busy: { root: /tmp, command: sleep 600 }
    YAML
    up!(runner)
    wait_for_fg('busy', 'sleep')

    assert_raises(SystemExit) do
      capture_io { runner.exec('busy', 'echo should-not-run') }
    end
  end

  def test_times_out_long_running_commands
    runner = with_scratch_session

    _out, _err, status = exec!(runner, 'scratch', 'sleep 30', timeout: 1)
    assert_equal 124, status
  end
end
