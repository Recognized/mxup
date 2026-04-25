# frozen_string_literal: true

require_relative 'lib/mxup/version'

Gem::Specification.new do |spec|
  spec.name     = 'mxup'
  spec.version  = Mxup::VERSION
  spec.authors  = ['Vladislav Saifulin']
  spec.email    = ['vladislav.saifulin@jetbrains.com']

  spec.summary     = 'Declarative tmux session manager with reconciliation.'
  spec.description = <<~DESC
    mxup brings a live tmux session into agreement with a YAML description of
    windows, commands, and layouts. It creates missing windows, restarts crashed
    ones, removes undeclared ones, and leaves healthy windows alone. Re-running
    `mxup up` is always safe.
  DESC

  spec.homepage              = 'https://github.com/Recognized/mxup'
  spec.license               = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata = {
    'homepage_uri'      => spec.homepage,
    'source_code_uri'   => spec.homepage,
    'bug_tracker_uri'   => "#{spec.homepage}/issues",
    'changelog_uri'     => "#{spec.homepage}/releases",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'bin/mxup',
    'examples/**/*',
    'README.md',
    'LICENSE'
  ]

  spec.bindir      = 'bin'
  spec.executables = ['mxup']
  spec.require_paths = ['lib']

  spec.add_development_dependency 'minitest', '~> 5.20'
  spec.add_development_dependency 'rake',     '~> 13.1'
end
