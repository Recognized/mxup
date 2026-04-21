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

  def pane_fg(window, pane_index: nil)
    panes = Mxup::Tmux.list_panes(SESSION)
    pane = if pane_index
             panes.find { |p| p[:name] == window && p[:pane_index] == pane_index }
           else
             panes.find { |p| p[:name] == window }
           end
    pane&.dig(:fg_cmd)
  end

  def wait_for_process(window, expected_fg, timeout: 5, pane_index: nil)
    deadline = Time.now + timeout
    loop do
      fg = pane_fg(window, pane_index: pane_index)
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

    wait_for_process('alpha', 'sleep', timeout: 10)
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

  def test_down_sends_interrupt_before_killing
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

    out, = capture_io { runner.down }
    assert_includes out, 'Stopping session'
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

  # --- Layouts: pane groups ---

  def test_up_creates_pane_group
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
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    assert Mxup::Tmux.has_session?(SESSION)
    names = window_names
    assert_includes names, 'main'
    assert_includes names, 'c'
    refute_includes names, 'a'
    refute_includes names, 'b'

    assert_equal 2, Mxup::Tmux.pane_count(SESSION, 'main')
  end

  def test_pane_titles_set_on_group
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    panes = Mxup::Tmux.list_panes(SESSION).select { |p| p[:name] == 'main' }
      .sort_by { |p| p[:pane_index] }
    assert_equal 'a', panes[0][:title]
    assert_equal 'b', panes[1][:title]
  end

  def test_three_pane_group_titles_and_roots
    dir_a = Dir.mktmpdir('mxup-a')
    dir_b = Dir.mktmpdir('mxup-b')
    dir_c = Dir.mktmpdir('mxup-c')

    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: #{dir_a}
          command: sleep 600
        b:
          root: #{dir_b}
          command: sleep 600
        c:
          root: #{dir_c}
          command: sleep 600
      layouts:
        full:
          grp:
            panes: [a, b, c]
            split: main-vertical
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    panes = Mxup::Tmux.list_panes(SESSION).select { |p| p[:name] == 'grp' }
      .sort_by { |p| p[:pane_index] }

    assert_equal 3, panes.size
    assert_equal 'a', panes[0][:title]
    assert_equal 'b', panes[1][:title]
    assert_equal 'c', panes[2][:title]

    assert_equal File.realpath(dir_a), File.realpath(panes[0][:cwd])
    assert_equal File.realpath(dir_b), File.realpath(panes[1][:cwd])
    assert_equal File.realpath(dir_c), File.realpath(panes[2][:cwd])

    wait_for_process('grp', 'sleep', pane_index: 0)
    wait_for_process('grp', 'sleep', pane_index: 1)
    wait_for_process('grp', 'sleep', pane_index: 2)

    assert_equal 'sleep', pane_fg('grp', pane_index: 0)
    assert_equal 'sleep', pane_fg('grp', pane_index: 1)
    assert_equal 'sleep', pane_fg('grp', pane_index: 2)
  ensure
    FileUtils.rm_rf([dir_a, dir_b, dir_c])
  end

  def test_layout_stored_in_environment
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a]
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    assert_equal 'full', Mxup::Tmux.show_environment(SESSION, 'MXUP_LAYOUT')
  end

  def test_up_with_flat_layout_creates_standalone_windows
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
      layouts:
        grouped:
          main:
            panes: [a, b]
        flat: {}
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, layout: 'flat')
    capture_io { runner.up }

    names = window_names
    assert_includes names, 'a'
    assert_includes names, 'b'
    refute_includes names, 'main'
  end

  # --- Layout switching ---

  def test_switch_layout_preserves_pids
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
      layouts:
        grouped:
          main:
            panes: [a, b]
            split: even-horizontal
        flat: {}
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, layout: 'grouped')
    capture_io { runner.up }

    sleep 1
    panes_before = Mxup::Tmux.list_panes(SESSION)
    pids_before = panes_before.map { |p| p[:pid] }.sort

    runner_switch = Mxup::Runner.new(config, layout: 'flat')
    capture_io { runner_switch.switch_layout('flat') }

    panes_after = Mxup::Tmux.list_panes(SESSION)
    pids_after = panes_after.map { |p| p[:pid] }.sort

    assert_equal pids_before, pids_after, "PIDs should survive layout switch"
    names = window_names
    assert_includes names, 'a'
    assert_includes names, 'b'
    assert_includes names, 'c'
  end

  def test_switch_layout_regroups_panes
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
      layouts:
        flat: {}
        compact:
          all:
            panes: [a, b, c]
            split: tiled
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, layout: 'flat')
    capture_io { runner.up }

    sleep 1
    assert_equal 3, window_names.size

    runner_switch = Mxup::Runner.new(config, layout: 'compact')
    capture_io { runner_switch.switch_layout('compact') }

    names = window_names
    assert_includes names, 'all'
    assert_equal 3, Mxup::Tmux.pane_count(SESSION, 'all')
  end

  def test_switch_layout_already_active
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a]
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    out, = capture_io { runner.switch_layout('full') }
    assert_includes out, "Already using layout 'full'"
  end

  # --- Reconcile with layout ---

  def test_reconcile_restarts_idle_pane_in_group
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    wait_for_process('main', 'sleep', pane_index: 0)
    wait_for_process('main', 'sleep', pane_index: 1)

    Mxup::Tmux.send_interrupt(SESSION, Mxup::Tmux.pane_target('main', 0))
    sleep 1

    out, = capture_io { runner.up }
    assert_includes out, 'a: restarted (was idle)'
    assert_includes out, 'b: running (sleep)'
  end

  # --- Restart with layout ---

  def test_restart_targets_pane_in_group
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 1

    out, = capture_io { runner.restart(['a']) }
    assert_includes out, 'a: restarted'
    refute_includes out, 'b'
  end

  # --- Show layouts ---

  def test_show_layouts
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
        flat: {}
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    out, = capture_io { runner.show_layouts }
    assert_includes out, 'full'
    assert_includes out, 'flat'
    assert_includes out, 'main=[a,b]'
    assert_includes out, 'all standalone'
  end

  # --- Status with layout ---

  def test_status_shows_layout_info
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        a:
          root: /tmp
          command: sleep 600
        b:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 2

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'layout: full'
    assert_includes out, 'main'
    assert_includes out, 'a, b'
  end

  # --- Window ordering with layout ---

  def test_window_order_with_layout
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
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    names = Mxup::Tmux.list_windows(SESSION)
      .sort_by { |w| w[:index] }
      .map { |w| w[:name] }

    assert_equal %w[main c], names
  end

  # --- Target resolution ---

  def test_target_prints_session_window_for_standalone
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        solo:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    out, = capture_io { runner.target(['solo']) }
    assert_equal "#{SESSION}:solo", out.strip
  end

  def test_target_prints_pane_address_for_grouped_window
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        alpha:
          root: /tmp
          command: sleep 600
        beta:
          root: /tmp
          command: sleep 600
        gamma:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          svc:
            panes: [alpha, beta, gamma]
            split: tiled
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    out, = capture_io { runner.target(['alpha']) }
    assert_equal "#{SESSION}:svc.0", out.strip

    out, = capture_io { runner.target(['beta']) }
    assert_equal "#{SESSION}:svc.1", out.strip

    out, = capture_io { runner.target(['gamma']) }
    assert_equal "#{SESSION}:svc.2", out.strip
  end

  def test_target_listing_all_windows
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        alpha:
          root: /tmp
          command: sleep 600
        beta:
          root: /tmp
          command: sleep 600
        solo:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          grp:
            panes: [alpha, beta]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    out, = capture_io { runner.target([]) }
    lines = out.strip.split("\n")
    assert_equal 3, lines.size
    assert_equal ['alpha', "#{SESSION}:grp.0"], lines[0].split("\t", 2)
    assert_equal ['beta',  "#{SESSION}:grp.1"], lines[1].split("\t", 2)
    assert_equal ['solo',  "#{SESSION}:solo"],  lines[2].split("\t", 2)
  end

  def test_target_unknown_window_aborts
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

    assert_raises(SystemExit) do
      capture_io { runner.target(['does-not-exist']) }
    end
  end

  def test_target_when_session_not_running
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)

    assert_raises(SystemExit) do
      capture_io { runner.target([]) }
    end
  end

  def test_status_prints_target_for_standalone
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

    out, = capture_io { runner.status(lines: 2) }
    assert_includes out, "target: #{SESSION}:w"
  end

  def test_status_finds_content_that_scrolled_past_requested_window
    # Emit a unique marker early, then pad the pane with many blank lines so
    # the marker sits well above the bottom -lines window. The status output
    # should still surface the marker because capture-pane now reads the full
    # scrollback and filters whitespace-only lines.
    Mxup::Tmux.new_session(SESSION, 'w', '/tmp')
    Mxup::Tmux.send_keys(SESSION, 'w', 'echo UNIQUE_MARKER_XYZ')
    sleep 0.5
    # 200 blank-ish lines of padding via printf newlines
    Mxup::Tmux.send_keys(SESSION, 'w', "printf '\\n%.0s' {1..200}")
    sleep 1

    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        w:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    out, = capture_io { runner.status(lines: 10) }
    assert_includes out, 'UNIQUE_MARKER_XYZ'
  end

  # --- Exec ---

  # exec terminates the process via `exit(rc)`. Wrap so we can collect both
  # the captured I/O and the resulting status in a single invocation.
  def run_exec(runner, *args, **kwargs)
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

  def test_exec_runs_command_and_captures_output
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 0.3

    out, _err, status = run_exec(runner, 'scratch', 'echo mxup-exec-marker-xyz')
    assert_equal 0, status
    assert_includes out, 'mxup-exec-marker-xyz'
  end

  def test_exec_propagates_non_zero_exit_code
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 0.3

    _out, _err, status = run_exec(runner, 'scratch', 'exit 7')
    assert_equal 7, status
  end

  def test_exec_accepts_session_prefixed_target
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 0.3

    out, _err, status = run_exec(runner, "#{SESSION}:scratch", 'echo via-prefixed-target')
    assert_equal 0, status
    assert_includes out, 'via-prefixed-target'
  end

  def test_exec_resolves_logical_name_in_pane_group
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        alpha:
          root: /tmp
        beta:
          root: /tmp
      layouts:
        full:
          grp:
            panes: [alpha, beta]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 0.5

    out, _err, status = run_exec(runner, 'beta', 'echo output-from-beta-pane')
    assert_equal 0, status
    assert_includes out, 'output-from-beta-pane'
  end

  def test_exec_rejects_busy_pane_without_force
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        busy:
          root: /tmp
          command: sleep 600
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    wait_for_process('busy', 'sleep', timeout: 5)

    assert_raises(SystemExit) do
      capture_io { runner.exec('busy', 'echo should-not-run') }
    end
  end

  def test_exec_rejects_mismatched_session_prefix
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    assert_raises(SystemExit) do
      capture_io { runner.exec('other-session:scratch', 'echo nope') }
    end
  end

  def test_exec_times_out_when_command_runs_too_long
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }
    sleep 0.3

    _out, _err, status = run_exec(runner, 'scratch', 'sleep 30', timeout: 1)
    assert_equal 124, status
  end

  def test_exec_dry_run_does_not_block
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        scratch:
          root: /tmp
    YAML

    config = Mxup::Config.new(path)
    # Real session so dry-run exec passes the "session running" gate.
    live = Mxup::Runner.new(config)
    capture_io { live.up }

    dry = Mxup::Runner.new(config, dry_run: true)
    # Would block forever if we actually tried to wait_for a marker.
    out, _err = capture_io { dry.exec('scratch', 'sleep 30') }
    assert_includes out, '[dry-run]'
  end

  def test_status_prints_target_for_grouped_panes
    path = write_config(<<~YAML)
      session: #{SESSION}
      windows:
        alpha:
          root: /tmp
          command: sleep 600
        beta:
          root: /tmp
          command: sleep 600
      layouts:
        full:
          svc:
            panes: [alpha, beta]
            split: even-horizontal
    YAML

    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config)
    capture_io { runner.up }

    out, = capture_io { runner.status(lines: 2) }
    assert_includes out, "target: #{SESSION}:svc.0"
    assert_includes out, "target: #{SESSION}:svc.1"
    assert_match(/^\s*alpha:\s*$/, out)
    assert_match(/^\s*beta:\s*$/,  out)
  end
end
