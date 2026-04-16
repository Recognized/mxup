#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

load File.expand_path('../bin/mxup', __dir__)

class ConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_config(content)
    path = File.join(@dir, 'test.yml')
    File.write(path, content)
    path
  end

  def test_parses_session_name
    path = write_config(<<~YAML)
      session: my-session
      windows:
        win1:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_equal 'my-session', config.session
  end

  def test_parses_setup
    path = write_config(<<~YAML)
      session: s
      setup: |
        echo hello
        echo world
      windows:
        w:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_equal "echo hello\necho world", config.setup
  end

  def test_setup_is_nil_when_absent
    path = write_config(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_nil config.setup
  end

  def test_parses_windows_in_order
    path = write_config(<<~YAML)
      session: s
      windows:
        alpha:
          root: /tmp
        beta:
          root: /tmp
        gamma:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_equal %w[alpha beta gamma], config.windows.map(&:name)
  end

  def test_parses_window_fields
    path = write_config(<<~YAML)
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
    config = Mxup::Config.new(path)
    win = config.windows.first

    assert_equal 'web', win.name
    assert_equal '/tmp', win.root  # /tmp doesn't have ~ so stays as-is
    assert_equal 'npm start', win.command
    assert_equal 'localhost:5432', win.wait_for
    assert_equal({ 'NODE_ENV' => 'production', 'PORT' => '3000' }, win.env)
  end

  def test_window_without_command
    path = write_config(<<~YAML)
      session: s
      windows:
        shell:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_nil config.windows.first.command
  end

  def test_expands_tilde_in_root
    path = write_config(<<~YAML)
      session: s
      windows:
        w:
          root: ~/some/path
    YAML
    config = Mxup::Config.new(path)
    assert_equal File.expand_path('~/some/path'), config.windows.first.root
  end

  def test_env_defaults_to_empty_hash
    path = write_config(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          command: echo hi
    YAML
    config = Mxup::Config.new(path)
    assert_equal({}, config.windows.first.env)
  end

  def test_missing_session_raises
    path = write_config(<<~YAML)
      windows:
        w:
          root: /tmp
    YAML
    assert_raises(KeyError) { Mxup::Config.new(path) }
  end

  def test_missing_windows_raises
    path = write_config(<<~YAML)
      session: s
    YAML
    assert_raises(KeyError) { Mxup::Config.new(path) }
  end

  def test_missing_root_raises
    path = write_config(<<~YAML)
      session: s
      windows:
        w:
          command: echo hi
    YAML
    assert_raises(KeyError) { Mxup::Config.new(path) }
  end
end

class AssembleCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def make_runner(yaml)
    path = File.join(@dir, 'test.yml')
    File.write(path, yaml)
    config = Mxup::Config.new(path)
    runner = Mxup::Runner.new(config, dry_run: true)
    [config, runner]
  end

  def assemble(runner, win)
    runner.send(:assemble_command, win)
  end

  def test_command_only
    config, runner = make_runner(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML
    result = assemble(runner, config.windows.first)
    assert_equal './run.sh', result
  end

  def test_setup_prepended
    config, runner = make_runner(<<~YAML)
      session: s
      setup: |
        echo setup
      windows:
        w:
          root: /tmp
          command: ./run.sh
    YAML
    result = assemble(runner, config.windows.first)
    assert_includes result, 'echo setup'
    assert_includes result, './run.sh'
    # Setup comes before the command
    assert result.index('echo setup') < result.index('./run.sh')
  end

  def test_wait_for_generates_nc_loop
    config, runner = make_runner(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          wait_for: localhost:5432
          command: ./run.sh
    YAML
    result = assemble(runner, config.windows.first)
    assert_includes result, "nc -z localhost 5432"
    assert_includes result, "Waiting for localhost:5432"
    assert_includes result, "localhost:5432 is ready"
    assert_includes result, './run.sh'
  end

  def test_env_exports
    config, runner = make_runner(<<~YAML)
      session: s
      windows:
        w:
          root: /tmp
          env:
            FOO: bar
            BAZ: "hello world"
          command: ./run.sh
    YAML
    result = assemble(runner, config.windows.first)
    assert_includes result, 'export FOO=bar'
    assert_includes result, 'export BAZ=hello\\ world'
    assert_includes result, './run.sh'
  end

  def test_no_command_window
    config, runner = make_runner(<<~YAML)
      session: s
      setup: |
        echo hi
      windows:
        shell:
          root: /tmp
    YAML
    result = assemble(runner, config.windows.first)
    assert_includes result, 'echo hi'
    refute_includes result, 'nil'
    refute_includes result, 'sleep'
  end

  def test_full_assembly_order
    config, runner = make_runner(<<~YAML)
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
    result = assemble(runner, config.windows.first)
    parts = result.split('; ')

    setup_idx = parts.index { |p| p.include?('direnv') }
    wait_idx = parts.index { |p| p.include?('Waiting') }
    export_idx = parts.index { |p| p.include?('export') }
    cmd_idx = parts.index { |p| p.include?('./start') }

    assert setup_idx < wait_idx, "setup should come before wait_for"
    assert wait_idx < export_idx, "wait_for should come before env"
    assert export_idx < cmd_idx, "env should come before command"
  end
end

class CLIConfigResolutionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_explicit_file_flag
    path = File.join(@dir, 'custom.yml')
    File.write(path, "session: s\nwindows:\n  w:\n    root: /tmp")

    cli = Mxup::CLI.new
    resolved = cli.send(:resolve_config, path, nil)
    assert_equal path, resolved
  end

  def test_explicit_file_not_found
    # Override CONFIG_DIR temporarily to avoid real configs
    old_dir = Mxup::CONFIG_DIR
    Mxup.send(:remove_const, :CONFIG_DIR)
    Mxup.const_set(:CONFIG_DIR, File.join(@dir, 'empty_config'))

    Dir.chdir(@dir) do
      cli = Mxup::CLI.new
      resolved = cli.send(:resolve_config, '/nonexistent/path.yml', 'nonexistent-config-name')
      assert_nil resolved
    end
  ensure
    Mxup.send(:remove_const, :CONFIG_DIR)
    Mxup.const_set(:CONFIG_DIR, old_dir)
  end

  def test_mxup_yml_in_cwd
    path = File.join(@dir, 'mxup.yml')
    File.write(path, "session: s\nwindows:\n  w:\n    root: /tmp")

    Dir.chdir(@dir) do
      cli = Mxup::CLI.new
      resolved = cli.send(:resolve_config, nil, nil)
      # Resolve both through realpath to handle macOS /tmp -> /private/tmp
      assert_equal File.realpath(path), File.realpath(resolved)
    end
  end
end

class ShellDetectionTest < Minitest::Test
  def test_common_shells_detected
    %w[zsh bash sh fish dash].each do |shell|
      assert_includes Mxup::SHELLS, shell, "#{shell} should be in SHELLS"
    end
  end

  def test_non_shells_not_detected
    %w[node java sleep gradle ruby python].each do |cmd|
      refute_includes Mxup::SHELLS, cmd, "#{cmd} should not be in SHELLS"
    end
  end
end

class LayoutConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_config(content)
    path = File.join(@dir, 'test.yml')
    File.write(path, content)
    path
  end

  def test_no_layouts_returns_empty
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    assert_equal({}, config.layouts)
    assert_equal([], config.layout_names)
    assert_nil config.default_layout
  end

  def test_parses_single_layout
    path = write_config(<<~YAML)
      session: s
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
    YAML
    config = Mxup::Config.new(path)
    assert_equal ['full'], config.layout_names
    assert_equal 'full', config.default_layout

    groups = config.groups_for('full')
    assert_equal 1, groups.size
    assert_equal 'main', groups.first.name
    assert_equal %w[a b], groups.first.window_names
    assert_equal 'even-horizontal', groups.first.split
  end

  def test_parses_multiple_layouts
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
        c:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
        compact:
          all:
            panes: [a, b, c]
            split: tiled
        flat: {}
    YAML
    config = Mxup::Config.new(path)
    assert_equal %w[full compact flat], config.layout_names
    assert_equal 'full', config.default_layout

    assert_equal 1, config.groups_for('full').size
    assert_equal 1, config.groups_for('compact').size
    assert_equal 0, config.groups_for('flat').size
  end

  def test_split_defaults_to_tiled
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
      layouts:
        default:
          main:
            panes: [a, b]
    YAML
    config = Mxup::Config.new(path)
    assert_equal 'tiled', config.groups_for('default').first.split
  end

  def test_invalid_window_reference_raises
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a, nonexistent]
    YAML
    assert_raises(ArgumentError) { Mxup::Config.new(path) }
  end

  def test_duplicate_window_in_groups_raises
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
      layouts:
        full:
          g1:
            panes: [a]
          g2:
            panes: [a, b]
    YAML
    assert_raises(ArgumentError) { Mxup::Config.new(path) }
  end

  def test_groups_for_nil_returns_empty
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a]
    YAML
    config = Mxup::Config.new(path)
    assert_equal [], config.groups_for(nil)
  end

  def test_effective_window_order_with_layout
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
        c:
          root: /tmp
        d:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a, b]
            split: even-horizontal
          side:
            panes: [c]
    YAML
    config = Mxup::Config.new(path)
    order = config.effective_window_order('full')

    assert_equal 3, order.size
    assert_equal :group, order[0][:type]
    assert_equal 'main', order[0][:name]
    assert_equal :group, order[1][:type]
    assert_equal 'side', order[1][:name]
    assert_equal :standalone, order[2][:type]
    assert_equal 'd', order[2][:name]
  end

  def test_effective_window_order_without_layout
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)
    order = config.effective_window_order(nil)

    assert_equal 2, order.size
    assert_equal :standalone, order[0][:type]
    assert_equal 'a', order[0][:name]
    assert_equal :standalone, order[1][:type]
    assert_equal 'b', order[1][:name]
  end

  def test_effective_window_order_flat_layout
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
      layouts:
        flat: {}
    YAML
    config = Mxup::Config.new(path)
    order = config.effective_window_order('flat')

    assert_equal 2, order.size
    assert order.all? { |e| e[:type] == :standalone }
  end

  def test_find_group_for_window
    path = write_config(<<~YAML)
      session: s
      windows:
        a:
          root: /tmp
        b:
          root: /tmp
        c:
          root: /tmp
      layouts:
        full:
          main:
            panes: [a, b]
    YAML
    config = Mxup::Config.new(path)

    group, idx = config.find_group_for_window('full', 'a')
    assert_equal 'main', group.name
    assert_equal 0, idx

    group, idx = config.find_group_for_window('full', 'b')
    assert_equal 'main', group.name
    assert_equal 1, idx

    assert_nil config.find_group_for_window('full', 'c')
  end

  def test_window_by_name
    path = write_config(<<~YAML)
      session: s
      windows:
        alpha:
          root: /tmp
          command: echo hi
        beta:
          root: /tmp
    YAML
    config = Mxup::Config.new(path)

    assert_equal 'alpha', config.window_by_name('alpha').name
    assert_equal 'echo hi', config.window_by_name('alpha').command
    assert_nil config.window_by_name('nonexistent')
  end
end
