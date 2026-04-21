#!/usr/bin/env ruby
# frozen_string_literal: true

# Central test helper. Every test file should `require_relative 'test_helper'`
# (or, for nested dirs, `require_relative '../test_helper'`).

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

# Load the library from source (not bin/), so tests don't pay the CLI dispatch
# cost and can exercise modules in isolation.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mxup'

module TestHelpers
  # Mixin that gives each test its own scratch directory. Include and call
  # super in setup/teardown if you need additional setup.
  module TmpDir
    def setup
      super
      @dir = Dir.mktmpdir('mxup-test-')
    end

    def teardown
      FileUtils.rm_rf(@dir) if @dir && Dir.exist?(@dir)
      super
    end

    # Write YAML to a file in the scratch dir and return its path. File name
    # defaults to `test.yml`; pass :name to override.
    def write_yaml(content, name: 'test.yml')
      path = File.join(@dir, name)
      File.write(path, content)
      path
    end

    # Parse a YAML string as a Mxup::Config without a physical dir hop — handy
    # when a test just needs a Config and doesn't care about the file.
    def make_config(yaml)
      Mxup::Config.new(write_yaml(yaml))
    end
  end

  # Mixin that lets a unit test stub Mxup::Tmux class methods and clean up
  # automatically on teardown. Use it instead of spinning a real tmux server
  # for tests that only exercise rendering / resolution logic.
  #
  # Example:
  #   class FooTest < Minitest::Test
  #     include TestHelpers::TmpDir
  #     include TestHelpers::TmuxStubs
  #
  #     def test_reports_not_running
  #       stub_tmux(has_session?: false)
  #       # ... runner.status etc ...
  #     end
  #   end
  #
  # Values may be either literal return values or procs (lambdas) that are
  # invoked with the original arguments for conditional answers.
  module TmuxStubs
    def setup
      super
      @tmux_stubs = {}
    end

    def teardown
      (@tmux_stubs || {}).each do |method, original|
        Mxup::Tmux.singleton_class.send(:remove_method, method)
        Mxup::Tmux.define_singleton_method(method, original) if original
      end
      @tmux_stubs = {}
      super
    end

    def stub_tmux(stubs)
      stubs.each do |method, value|
        unless @tmux_stubs.key?(method)
          @tmux_stubs[method] = Mxup::Tmux.respond_to?(method) \
            ? Mxup::Tmux.singleton_method(method) \
            : nil
        end
        Mxup::Tmux.define_singleton_method(method) do |*args|
          value.respond_to?(:call) ? value.call(*args) : value
        end
      end
    end

    # Build a pane record matching the shape Mxup::Tmux.list_panes returns.
    # Sensible defaults make it easy to describe "a running pane" or "an
    # idle pane" without restating everything.
    def pane(name:, pane_index: 0, window_index: nil, pid: 1234,
            cwd: '/tmp', fg_cmd: 'sleep', title: nil)
      {
        window_index: window_index || pane_index,
        name: name,
        pane_index: pane_index,
        pid: pid,
        cwd: cwd,
        fg_cmd: fg_cmd,
        title: title || name
      }
    end

    # Build a window record matching Mxup::Tmux.list_windows' shape.
    def window(name:, index: 0)
      { index: index, name: name }
    end
  end
end
