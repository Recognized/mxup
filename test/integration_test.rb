#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

load File.expand_path('../bin/mxup', __dir__)

# Integration tests that create real tmux sessions.
# Requires tmux to be installed and running (or able to start a server).
class IntegrationTest < Minitest::Test
  SESSION = 'mxup-test'

  def setup
    @dir = Dir.mktmpdir
    kill_session
  end

  def teardown
    kill_session
    FileUtils.rm_rf(@dir)
  end

  def kill_session
    system("tmux kill-session -t #{SESSION} 2>/dev/null")
  end

  def write_config(content)
    path = File.join(@dir, 'test.yml')
    File.write(path, content)
    path
  end

  def window_names
    return [] unless Mxup::Tmux.has_session?(SESSION)
    Mxup::Tmux.list_windows(SESSION).map { |w| w[:name] }
  end

  def pane_fg(window)
    panes = Mxup::Tmux.list_panes(SESSION)
    pane = panes.find { |p| p[:name] == window }
    pane&.dig(:fg_cmd)
  end

  def wait_for_process(window, expected_fg, timeout: 5)
    deadline = Time.now + timeout
    loop do
      fg = pane_fg(window)
      return fg if fg == expected_fg || Time.now > deadline
      sleep 0.3
    end
  end

  # --- Fresh start ---

  def test_up_creates_session_from_scratch
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        alpha:
          root: /tmp
          command: sleep 600
        beta:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.up }

    assert Mxup::Tmux.has_session?(SESSION), "Session should exist"
    assert_equal %w[alpha beta], window_names
    assert_includes out, 'alpha: created'
    assert_includes out, 'beta: created'

    wait_for_process('alpha', 'sleep')
    assert_equal 'sleep', pane_fg('alpha')
  end

  # --- Reconciliation: healthy session ---

  def test_up_skips_running_processes
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    wait_for_process('w', 'sleep')

    out, = capture_io { runner.up }
    assert_includes out, 'w: running (sleep) — ok'
  end

  # --- Reconciliation: crashed process ---

  def test_up_restarts_idle_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    wait_for_process('w', 'sleep')

    Mxup::Tmux.send_interrupt(SESSION, 'w')
    sleep 1

    out, = capture_io { runner.up }
    assert_includes out, 'w: restarted (was idle)'
  end

  # --- Reconciliation: missing window ---

  def test_up_creates_missing_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        keep:
          root: /tmp
          command: sleep 600
        new_one:
          root: /tmp
          command: sleep 600
    YAML

    Mxup::Tmux.new_session(SESSION, 'keep', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'keep', 'sleep 600')

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.up }
    assert_includes out, 'new_one: created (was missing)'
    assert_includes window_names, 'new_one'
  end

  # --- Reconciliation: extra window ---

  def test_up_removes_extra_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        keep:
          root: /tmp
          command: sleep 600
    YAML

    Mxup::Tmux.new_session(SESSION, 'keep', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'keep', 'sleep 600')
    Mxup::Tmux.new_window(SESSION, 'rogue', '/tmp')

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    _, err = capture_io { runner.up }
    assert_includes err, 'rogue: not in config — removing'
    refute_includes window_names, 'rogue'
  end

  # --- Down ---

  def test_down_kills_session
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    assert Mxup::Tmux.has_session?(SESSION)

    capture_io { runner.down }
    refute Mxup::Tmux.has_session?(SESSION)
  end

  def test_down_when_not_running
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.down }
    assert_includes out, 'not running'
  end

  # --- Restart ---

  def test_restart_single_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    wait_for_process('a', 'sleep')
    wait_for_process('b', 'sleep')

    out, = capture_io { runner.restart(['a']) }
    assert_includes out, 'a: restarted'
    refute_includes out, 'b'
  end

  def test_restart_multiple_windows
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
        c:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    wait_for_process('a', 'sleep')

    out, = capture_io { runner.restart(['a,c']) }
    assert_includes out, 'a: restarted'
    assert_includes out, 'c: restarted'
    refute_includes out, 'b:'
  end

  def test_restart_all_windows
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    wait_for_process('a', 'sleep')

    out, = capture_io { runner.restart([]) }
    assert_includes out, 'a: restarted'
    assert_includes out, 'b: restarted'
  end

  # --- Dry run ---

  def test_dry_run_does_not_create_session
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, dry_run: true)

    out, = capture_io { runner.up }
    refute Mxup::Tmux.has_session?(SESSION)
    assert_includes out, '[dry-run]'
  end

  def test_dry_run_reconcile_does_not_modify
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        keep:
          root: /tmp
          command: sleep 600
    YAML

    Mxup::Tmux.new_session(SESSION, 'keep', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'keep', 'sleep 600')
    Mxup::Tmux.new_window(SESSION, 'extra', '/tmp')
    sleep 0.5

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, dry_run: true)

    capture_io { runner.up }
    assert_includes window_names, 'extra', "Extra window should survive dry-run"
  end

  # --- Status ---

  def test_status_shows_session_info
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    capture_io { runner.up }
    sleep 2

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, "SESSION: #{SESSION}"
    assert_includes out, '[0] w'
    assert_includes out, 'sleep'
  end

  def test_status_when_not_running
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'NOT RUNNING'
  end

  def test_status_flags_missing_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        exists:
          root: /tmp
          command: sleep 600
        gone:
          root: /tmp
          command: sleep 600
    YAML

    Mxup::Tmux.new_session(SESSION, 'exists', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'exists', 'sleep 600')

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'gone'
    assert_includes out, 'MISSING'
  end

  def test_status_flags_extra_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        declared:
          root: /tmp
          command: sleep 600
    YAML

    Mxup::Tmux.new_session(SESSION, 'declared', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'declared', 'sleep 600')
    Mxup::Tmux.new_window(SESSION, 'undeclared', '/tmp')
    sleep 0.5

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'undeclared'
    assert_includes out, '[NOT IN CONFIG]'
  end

  # --- Window ordering ---

  def test_windows_reordered_after_reconcile
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        first:
          root: /tmp
          command: sleep 600
        second:
          root: /tmp
          command: sleep 600
        third:
          root: /tmp
          command: sleep 600
    YAML

    # Create in reverse order
    Mxup::Tmux.new_session(SESSION, 'third', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'third', 'sleep 600')
    Mxup::Tmux.new_window(SESSION, 'second', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'second', 'sleep 600')
    Mxup::Tmux.new_window(SESSION, 'first', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'first', 'sleep 600')
    sleep 1

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    names = Mxup::Tmux.list_windows(SESSION)
      .sort_by { |w| w[:index] }
      .map { |w| w[:name] }

    assert_equal %w[first second third], names
  end
end
