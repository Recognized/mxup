#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the pure / side-effect-free parts of mxup.
#
# Structure:
#   Mxup::WaitSpec      — readiness spec parsing
#   Mxup::Config        — YAML parsing, validation, derived views
#   Mxup::Launcher      — per-window launcher script generation
#   Mxup::CLI           — config resolution helpers
#   Mxup top-level      — module-level constants
#
# These tests do NOT touch tmux. Integration tests live in integration_test.rb.

require_relative 'test_helper'

# ---------------------------------------------------------------------------
# WaitSpec
# ---------------------------------------------------------------------------

class WaitSpecTest < Minitest::Test
  def parse(raw)
    Mxup::WaitSpec.parse(raw)
  end

  def test_nil_input_returns_nil
    assert_nil parse(nil)
  end

  def test_string_is_interpreted_as_tcp
    spec = parse('localhost:5432')
    assert_equal :tcp,              spec.type
    assert_equal 'localhost:5432',  spec.target
    assert_equal 'localhost:5432',  spec.label
    assert_equal 2,                 spec.interval
    assert_nil                      spec.timeout
  end

  def test_hash_forms_for_each_check_type
    {
      'tcp'    => 'db:5432',
      'http'   => 'http://localhost:8080/health',
      'path'   => '/tmp/app.sock',
      'script' => 'pg_isready -h localhost'
    }.each do |type, target|
      spec = parse(type => target)
      assert_equal type.to_sym, spec.type, "type #{type}"
      assert_equal target,      spec.target, "target for #{type}"
    end
  end

  def test_script_uses_generic_default_label
    spec = parse('script' => 'pg_isready')
    assert_equal 'readiness check', spec.label
  end

  def test_explicit_label_wins_over_default
    spec = parse('script' => 'pg_isready', 'label' => 'postgres')
    assert_equal 'postgres', spec.label
  end

  def test_timeout_and_interval_are_preserved
    spec = parse('tcp' => 'a:1', 'timeout' => 60, 'interval' => 5)
    assert_equal 60, spec.timeout
    assert_equal 5,  spec.interval
  end

  def test_missing_check_type_raises
    assert_raises(ArgumentError) { parse('timeout' => 10) }
  end

  def test_multiple_check_types_raise
    assert_raises(ArgumentError) { parse('tcp' => 'a:1', 'http' => 'http://b') }
  end

  def test_invalid_top_level_type_raises
    assert_raises(ArgumentError) { parse(42) }
  end
end

# ---------------------------------------------------------------------------
# Config (non-layout fields)
# ---------------------------------------------------------------------------

class ConfigTest < Minitest::Test
  include TestHelpers::TmpDir

  def test_session_name_is_parsed
    assert_equal 'my-session', make_config(<<~YAML).session
      session: my-session
      windows:
        w:
          root: /tmp
    YAML
  end

  def test_setup_is_parsed_and_stripped
    config = make_config(<<~YAML)
      session: s
      setup: |
        echo hello
        echo world
      windows:
        w:
          root: /tmp
    YAML
    assert_equal "echo hello\necho world", config.setup
  end

  def test_setup_defaults_to_nil
    config = make_config(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
    YAML
    assert_nil config.setup
  end

  def test_windows_preserve_yaml_declaration_order
    config = make_config(<<~YAML)
      session: s
      windows:
        alpha:
          root: /tmp
        beta:
          root: /tmp
        gamma:
          root: /tmp
    YAML
    assert_equal %w[alpha beta gamma], config.windows.map(&:name)
  end

  def test_window_fields_are_captured
    win = make_config(<<~YAML).windows.first
      session: s
      windows:
        web:
          root: /tmp
          command: npm start
          wait_for: localhost:5432
          env:
            NODE_ENV: production
            PORT: "3000"
    YAML

    assert_equal 'web',                                       win.name
    assert_equal '/tmp',                                      win.root
    assert_equal 'npm start',                                 win.command
    assert_instance_of Mxup::WaitSpec,                        win.wait_for
    assert_equal 'localhost:5432',                            win.wait_for.target
    assert_equal({ 'NODE_ENV' => 'production', 'PORT' => '3000' }, win.env)
  end

  def test_window_without_command_has_nil_command
    config = make_config(<<~YAML)
      session: s
      windows:
        shell:
          root: /tmp
    YAML
    assert_nil config.windows.first.command
  end

  def test_env_defaults_to_empty_hash
    config = make_config(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          command: echo hi
    YAML
    assert_equal({}, config.windows.first.env)
  end

  def test_tilde_in_root_is_expanded
    config = make_config(<<~YAML)
      session: s
      windows:
        w:
          root: ~/some/path
    YAML
    assert_equal File.expand_path('~/some/path'), config.windows.first.root
  end

  def test_window_by_name_finds_declared_windows
    config = make_config(<<~YAML)
      session: s
      windows:
        alpha:
          root: /tmp
          command: echo hi
        beta:
          root: /tmp
    YAML

    assert_equal 'echo hi', config.window_by_name('alpha').command
    assert_nil              config.window_by_name('ghost')
  end

  def test_missing_required_keys_raise
    [
      "windows:\n  w:\n    root: /tmp\n",                    # no session
      "session: s\n",                                         # no windows
      "session: s\nwindows:\n  w:\n    command: echo hi\n"    # no root
    ].each do |yaml|
      assert_raises(KeyError) { make_config(yaml) }
    end
  end
end

# ---------------------------------------------------------------------------
# Config — layouts & derived views
# ---------------------------------------------------------------------------

class ConfigLayoutsTest < Minitest::Test
  include TestHelpers::TmpDir

  def three_window_config(extra = '')
    make_config(<<~YAML)
      session: s
      windows:
        a: { root: /tmp }
        b: { root: /tmp }
        c: { root: /tmp }
      #{extra}
    YAML
  end

  def test_config_without_layouts_has_empty_view
    config = three_window_config
    assert_equal({}, config.layouts)
    assert_equal([], config.layout_names)
    assert_nil      config.default_layout
  end

  def test_first_declared_layout_is_the_default
    config = three_window_config(<<~YAML)
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
        compact:
          all: { panes: [a, b, c], split: tiled }
        flat: {}
    YAML
    assert_equal %w[full compact flat], config.layout_names
    assert_equal 'full',                config.default_layout
  end

  def test_pane_group_defaults_split_to_tiled
    config = three_window_config(<<~YAML)
      layouts:
        default:
          main: { panes: [a, b] }
    YAML
    assert_equal 'tiled', config.groups_for('default').first.split
  end

  def test_groups_for_nil_returns_empty
    config = three_window_config(<<~YAML)
      layouts:
        full:
          main: { panes: [a] }
    YAML
    assert_equal [], config.groups_for(nil)
  end

  def test_unknown_window_in_group_raises
    assert_raises(ArgumentError) do
      three_window_config(<<~YAML)
        layouts:
          full:
            main: { panes: [a, nonexistent] }
      YAML
    end
  end

  def test_window_appearing_in_multiple_groups_raises
    assert_raises(ArgumentError) do
      three_window_config(<<~YAML)
        layouts:
          full:
            g1: { panes: [a] }
            g2: { panes: [a, b] }
      YAML
    end
  end

  def test_effective_window_order_mixes_groups_and_standalones
    config = make_config(<<~YAML)
      session: s
      windows:
        a: { root: /tmp }
        b: { root: /tmp }
        c: { root: /tmp }
        d: { root: /tmp }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
          side: { panes: [c] }
    YAML

    order = config.effective_window_order('full')
    assert_equal 3,           order.size
    assert_equal :group,      order[0][:type]
    assert_equal 'main',      order[0][:name]
    assert_equal :group,      order[1][:type]
    assert_equal 'side',      order[1][:name]
    assert_equal :standalone, order[2][:type]
    assert_equal 'd',         order[2][:name]
  end

  def test_effective_window_order_without_layout_is_all_standalone
    config = three_window_config
    order = config.effective_window_order(nil)
    assert_equal 3, order.size
    assert(order.all? { |e| e[:type] == :standalone })
  end

  def test_effective_window_order_with_empty_layout_is_all_standalone
    config = three_window_config("layouts:\n  flat: {}\n")
    order = config.effective_window_order('flat')
    assert_equal 3, order.size
    assert(order.all? { |e| e[:type] == :standalone })
  end

  def test_find_group_for_window_returns_group_and_index
    config = three_window_config(<<~YAML)
      layouts:
        full:
          main: { panes: [a, b] }
    YAML

    group, idx = config.find_group_for_window('full', 'b')
    assert_equal 'main', group.name
    assert_equal 1,      idx
  end

  def test_find_group_for_window_returns_nil_for_standalone
    config = three_window_config(<<~YAML)
      layouts:
        full:
          main: { panes: [a, b] }
    YAML
    assert_nil config.find_group_for_window('full', 'c')
  end
end

# ---------------------------------------------------------------------------
# Launcher — script generation (pure; writes to tmp dirs only)
# ---------------------------------------------------------------------------

class LauncherTest < Minitest::Test
  include TestHelpers::TmpDir

  # Fresh Launcher scoped to our tmp dir so we never touch the real
  # ~/.local/share/mxup while the test suite runs.
  def launcher_for(yaml)
    config = make_config(yaml)
    [config, Mxup::Launcher.new(config, runtime_root: File.join(@dir, 'runtime'))]
  end

  # --- command_for --------------------------------------------------------

  def test_command_for_sources_the_launcher_script
    config, launcher = launcher_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML
    result = launcher.command_for(config.windows.first)
    assert_match(/\A\. .+\/w_launcher\.sh\z/, result)
  end

  def test_command_for_empty_window_returns_empty_string
    config, launcher = launcher_for(<<~YAML)
      session: s
      windows:
        shell:
          root: /tmp
    YAML
    assert_equal '', launcher.command_for(config.windows.first)
  end

  # --- build_script content ----------------------------------------------

  def script_for(yaml, window_name = nil)
    config, launcher = launcher_for(yaml)
    win = window_name ? config.window_by_name(window_name) : config.windows.first
    launcher.build_script(win)
  end

  def test_script_changes_into_the_window_root
    assert_includes script_for(<<~YAML), 'cd /tmp'
      session: s
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML
  end

  def test_script_embeds_global_setup_before_command
    script = script_for(<<~YAML)
      session: s
      setup: |
        echo setup
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML
    assert_includes script, 'echo setup'
    assert_includes script, './run.sh'
    assert script.index('echo setup') < script.index('./run.sh'),
           'setup should run before command'
  end

  def test_script_inlines_wait_for_before_command
    script = script_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: localhost:5432
          command: ./run.sh
    YAML
    assert_includes script, 'nc -z localhost 5432'
    assert script.index('nc -z') < script.index('./run.sh'),
           'wait_for should run before command'
  end

  def test_script_exports_env_vars_with_shell_escaping
    script = script_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          env:
            FOO: bar
            BAZ: "hello world"
          command: ./run.sh
    YAML
    assert_includes script, 'export FOO=bar'
    assert_includes script, 'export BAZ=hello\\ world'
  end

  def test_script_with_no_command_still_runs_setup
    script = script_for(<<~YAML)
      session: s
      setup: |
        echo hi
      windows:
        shell:
          root: /tmp
    YAML
    assert_includes script, 'echo hi'
    refute_includes script, 'nil'
  end

  def test_script_section_order_is_setup_wait_env_command
    script = script_for(<<~YAML)
      session: s
      setup: |
        direnv allow
      windows:
        w:
          root: /tmp
          wait_for: db:5432
          env:
            KEY: val
          command: ./start
    YAML

    positions = {
      setup:   script.index('direnv'),
      wait:    script.index('Waiting for'),
      export:  script.index('export'),
      command: script.index('./start')
    }

    refute_includes positions.values, nil, 'all sections should be present'
    ordered = positions.values
    assert_equal ordered.sort, ordered,
                 "expected setup < wait < env < command, got #{positions.inspect}"
  end

  # --- build_wait_block by check type -----------------------------------

  def build_wait_block_for(yaml)
    _, launcher = launcher_for(yaml)
    spec = launcher.instance_variable_get(:@config).windows.first.wait_for
    launcher.build_wait_block(spec).join("\n")
  end

  def test_wait_block_tcp_uses_nc
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: localhost:5432
    YAML
    assert_includes block, 'nc -z localhost 5432'
    assert_includes block, 'Waiting for localhost:5432'
    assert_includes block, 'localhost:5432 is ready'
    assert_includes block, 'still waiting'
    assert_includes block, 'sleep 2'
  end

  def test_wait_block_http_uses_curl
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: { http: 'http://localhost:8080/health' }
    YAML
    assert_includes block, 'curl -sf'
    assert_includes block, 'http://localhost:8080/health'
  end

  def test_wait_block_path_uses_test_e
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: { path: /tmp/app.sock }
    YAML
    assert_includes block, '[ -e'
    assert_includes block, '/tmp/app.sock'
  end

  def test_wait_block_script_runs_command_verbatim_with_optional_label
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for:
            script: pg_isready -h localhost
            label: postgres
    YAML
    assert_includes block, 'pg_isready -h localhost'
    assert_includes block, 'Waiting for postgres'
    assert_includes block, 'postgres is ready'
  end

  def test_wait_block_with_timeout_includes_elapsed_tracking
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for:
            tcp: localhost:5432
            timeout: 60
    YAML
    assert_includes block, '_mxup_wait_start=$(date +%s)'
    assert_includes block, 'Timed out waiting for localhost:5432 after 60s'
    assert_includes block, 'of 60s'
  end

  def test_wait_block_honours_custom_interval
    block = build_wait_block_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for:
            tcp: localhost:5432
            interval: 5
    YAML
    assert_includes block, 'sleep 5'
    refute_includes block, 'sleep 2'
  end

  # --- write_all / cleanup on disk --------------------------------------

  def test_write_all_creates_executable_scripts_only_for_nonempty_windows
    config, launcher = launcher_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: localhost:5432
          command: ./run.sh
        with_cmd:
          root: /tmp
          command: echo hi
        shell:
          root: /tmp
    YAML

    launcher.write_all

    w_path = launcher.script_path('w')
    assert File.exist?(w_path),       'launcher script for w should exist'
    assert File.executable?(w_path),  'launcher script should be executable'
    contents = File.read(w_path)
    assert_includes contents, 'nc -z localhost 5432'
    assert_includes contents, './run.sh'

    assert File.exist?(launcher.script_path('with_cmd')),
           'launcher script for with_cmd should exist'
    refute File.exist?(launcher.script_path('shell')),
           'no launcher script for pure-shell windows'
  end

  def test_cleanup_removes_runtime_dir
    _, launcher = launcher_for(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML

    launcher.write_all
    assert Dir.exist?(launcher.session_runtime_dir)
    launcher.cleanup
    refute Dir.exist?(launcher.session_runtime_dir)
  end
end

# ---------------------------------------------------------------------------
# CLI — config resolution
# ---------------------------------------------------------------------------

class CLIConfigResolutionTest < Minitest::Test
  include TestHelpers::TmpDir

  def resolve(file:, name:, config_dir: nil)
    original = Mxup::CONFIG_DIR
    if config_dir
      Mxup.send(:remove_const, :CONFIG_DIR)
      Mxup.const_set(:CONFIG_DIR, config_dir)
    end
    Mxup::CLI.new.send(:resolve_config, file, name)
  ensure
    if config_dir
      Mxup.send(:remove_const, :CONFIG_DIR)
      Mxup.const_set(:CONFIG_DIR, original)
    end
  end

  def test_explicit_existing_file_is_returned_unchanged
    path = write_yaml("session: s\nwindows:\n  w:\n    root: /tmp")
    assert_equal path, resolve(file: path, name: nil)
  end

  def test_explicit_missing_file_returns_nil
    resolved = resolve(
      file: '/nonexistent/path.yml',
      name: 'nonexistent-config',
      config_dir: File.join(@dir, 'empty')
    )
    assert_nil resolved
  end

  def test_mxup_yml_in_cwd_is_picked_up
    path = write_yaml("session: s\nwindows:\n  w:\n    root: /tmp", name: 'mxup.yml')
    Dir.chdir(@dir) do
      assert_equal File.realpath(path),
                   File.realpath(resolve(file: nil, name: nil))
    end
  end
end

# ---------------------------------------------------------------------------
# Module-level constants — just a sanity check, not a regression trap
# ---------------------------------------------------------------------------

class ConstantsTest < Minitest::Test
  def test_shells_contains_common_interactive_shells
    %w[zsh bash sh fish dash].each { |s| assert_includes Mxup::SHELLS, s }
  end

  def test_shells_excludes_typical_foreground_processes
    %w[node java sleep gradle ruby python].each do |cmd|
      refute_includes Mxup::SHELLS, cmd
    end
  end
end

# ---------------------------------------------------------------------------
# Runner#target — pure pane-address formatting; tested by stubbing Tmux state
# ---------------------------------------------------------------------------

class RunnerTargetTest < Minitest::Test
  include TestHelpers::TmpDir
  include TestHelpers::TmuxStubs

  SESSION = 's'

  def runner_for(yaml)
    config = make_config("session: #{SESSION}\n#{yaml}")
    Mxup::Runner.new(config)
  end

  def test_prints_bare_window_for_standalone
    stub_tmux(
      has_session?: true,
      list_panes: [pane(name: 'solo')],
      list_windows: [window(name: 'solo')]
    )

    runner = runner_for(<<~YAML)
      windows:
        solo: { root: /tmp, command: sleep 600 }
    YAML

    out, = capture_io { runner.target(['solo']) }
    assert_equal "#{SESSION}:solo", out.strip
  end

  def test_prints_pane_address_inside_group
    stub_tmux(
      has_session?: true,
      list_windows: [window(name: 'svc')],
      list_panes: [
        pane(name: 'svc', pane_index: 0, title: 'alpha'),
        pane(name: 'svc', pane_index: 1, title: 'beta'),
        pane(name: 'svc', pane_index: 2, title: 'gamma')
      ]
    )

    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
        gamma: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          svc: { panes: [alpha, beta, gamma], split: tiled }
    YAML

    {
      'alpha' => "#{SESSION}:svc.0",
      'beta'  => "#{SESSION}:svc.1",
      'gamma' => "#{SESSION}:svc.2"
    }.each do |name, expected|
      out, = capture_io { runner.target([name]) }
      assert_equal expected, out.strip
    end
  end

  def test_listing_all_windows_prints_tab_separated_table
    stub_tmux(
      has_session?: true,
      list_windows: [window(name: 'grp'), window(name: 'solo', index: 1)],
      list_panes: [
        pane(name: 'grp',  pane_index: 0, title: 'alpha'),
        pane(name: 'grp',  pane_index: 1, title: 'beta'),
        pane(name: 'solo', pane_index: 0, window_index: 1)
      ]
    )

    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
        solo:  { root: /tmp, command: sleep 600 }
      layouts:
        full:
          grp: { panes: [alpha, beta], split: even-horizontal }
    YAML

    out, = capture_io { runner.target([]) }
    lines = out.strip.split("\n")
    assert_equal 3, lines.size
    assert_equal ['alpha', "#{SESSION}:grp.0"], lines[0].split("\t", 2)
    assert_equal ['beta',  "#{SESSION}:grp.1"], lines[1].split("\t", 2)
    assert_equal ['solo',  "#{SESSION}:solo"],  lines[2].split("\t", 2)
  end

  def test_unknown_window_aborts
    stub_tmux(has_session?: true, list_windows: [window(name: 'w')],
              list_panes: [pane(name: 'w')])

    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    assert_raises(SystemExit) { capture_io { runner.target(['does-not-exist']) } }
  end

  def test_aborts_when_session_not_running
    stub_tmux(has_session?: false)

    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    assert_raises(SystemExit) { capture_io { runner.target([]) } }
  end
end

# ---------------------------------------------------------------------------
# StatusView — rendering, driven by stubbed tmux state
# ---------------------------------------------------------------------------

class StatusViewTest < Minitest::Test
  include TestHelpers::TmpDir
  include TestHelpers::TmuxStubs

  SESSION = 's'

  def runner_for(yaml, layout: nil)
    config = make_config("session: #{SESSION}\n#{yaml}")
    Mxup::Runner.new(config, layout: layout)
  end

  def stub_running(panes:, windows: nil, layout: nil, capture: '')
    wins = windows || panes.map { |p| window(name: p[:name], index: p[:window_index]) }.uniq
    stub_tmux(
      has_session?: true,
      session_created: Time.now.to_i.to_s,
      list_panes: panes,
      list_windows: wins,
      show_environment: layout,
      capture_pane: capture
    )
  end

  def test_reports_when_session_not_running
    stub_tmux(has_session?: false)
    runner = runner_for("windows:\n  w: { root: /tmp }\n")

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'NOT RUNNING'
  end

  def test_flags_missing_window
    stub_running(panes: [pane(name: 'exists', fg_cmd: 'sleep')])

    runner = runner_for(<<~YAML)
      windows:
        exists: { root: /tmp, command: sleep 600 }
        gone:   { root: /tmp, command: sleep 600 }
    YAML

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'gone'
    assert_includes out, 'MISSING'
  end

  def test_flags_extra_window
    stub_running(panes: [
      pane(name: 'declared',   fg_cmd: 'sleep'),
      pane(name: 'undeclared', window_index: 1, fg_cmd: 'bash')
    ])

    runner = runner_for(<<~YAML)
      windows:
        declared: { root: /tmp, command: sleep 600 }
    YAML

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'undeclared'
    assert_includes out, '[NOT IN CONFIG]'
  end

  def test_shows_active_layout_and_group_membership
    stub_running(
      layout: 'full',
      panes: [
        pane(name: 'main', pane_index: 0, title: 'a', fg_cmd: 'sleep'),
        pane(name: 'main', pane_index: 1, title: 'b', fg_cmd: 'sleep')
      ],
      windows: [window(name: 'main')]
    )

    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
        b: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a, b], split: even-horizontal }
    YAML

    out, = capture_io { runner.status(lines: 5) }
    assert_includes out, 'layout: full'
    assert_includes out, 'main'
    assert_includes out, 'a, b'
  end

  def test_prints_target_address_for_standalone_window
    stub_running(panes: [pane(name: 'w', fg_cmd: 'sleep')])
    runner = runner_for(<<~YAML)
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    out, = capture_io { runner.status(lines: 2) }
    assert_includes out, "target: #{SESSION}:w"
  end

  def test_prints_target_address_for_each_grouped_pane
    stub_running(
      layout: 'full',
      panes: [
        pane(name: 'svc', pane_index: 0, title: 'alpha', fg_cmd: 'sleep'),
        pane(name: 'svc', pane_index: 1, title: 'beta',  fg_cmd: 'sleep')
      ],
      windows: [window(name: 'svc')]
    )

    runner = runner_for(<<~YAML)
      windows:
        alpha: { root: /tmp, command: sleep 600 }
        beta:  { root: /tmp, command: sleep 600 }
      layouts:
        full:
          svc: { panes: [alpha, beta], split: even-horizontal }
    YAML

    out, = capture_io { runner.status(lines: 2) }
    assert_includes out, "target: #{SESSION}:svc.0"
    assert_includes out, "target: #{SESSION}:svc.1"
    assert_match(/^\s*alpha:\s*$/, out)
    assert_match(/^\s*beta:\s*$/,  out)
  end

  def test_surfaces_content_that_scrolled_past_the_lines_window
    # capture_pane returns a big scroll with the marker buried; StatusView
    # filters blanks then tails, so as long as the marker lives in a
    # non-blank line it should still show up.
    scroll = "UNIQUE_MARKER_XYZ\n" + ("\n" * 200) + "bash$\n"
    stub_running(
      panes: [pane(name: 'w', fg_cmd: 'bash')],
      capture: scroll
    )

    runner = runner_for("windows:\n  w: { root: /tmp }\n")

    out, = capture_io { runner.status(lines: 10) }
    assert_includes out, 'UNIQUE_MARKER_XYZ'
  end
end

# ---------------------------------------------------------------------------
# LayoutManager.show / no-op switch — pure rendering, stubbed tmux
# ---------------------------------------------------------------------------

class LayoutManagerShowTest < Minitest::Test
  include TestHelpers::TmpDir
  include TestHelpers::TmuxStubs

  def runner_for(yaml)
    Mxup::Runner.new(make_config("session: s\n#{yaml}"))
  end

  def test_show_layouts_prints_all_layouts_with_groups
    stub_tmux(has_session?: false)

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

  def test_switching_to_active_layout_is_a_noop
    stub_tmux(
      has_session?: true,
      show_environment: 'full',
      list_panes: [pane(name: 'main', pane_index: 0, title: 'a', fg_cmd: 'sleep')],
      list_windows: [window(name: 'main')]
    )

    runner = runner_for(<<~YAML)
      windows:
        a: { root: /tmp, command: sleep 600 }
      layouts:
        full:
          main: { panes: [a] }
    YAML

    out, = capture_io { runner.switch_layout('full') }
    assert_includes out, "Already using layout 'full'"
  end
end

# ---------------------------------------------------------------------------
# Runner#down — fast branches that don't need a real session
# ---------------------------------------------------------------------------

class RunnerDownTest < Minitest::Test
  include TestHelpers::TmpDir
  include TestHelpers::TmuxStubs

  def test_noop_when_no_session_running
    stub_tmux(has_session?: false)

    runner = Mxup::Runner.new(make_config(<<~YAML))
      session: s
      windows:
        w: { root: /tmp, command: sleep 600 }
    YAML

    out, = capture_io { runner.down }
    assert_includes out, 'not running'
  end
end
