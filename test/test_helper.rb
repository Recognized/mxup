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
end
