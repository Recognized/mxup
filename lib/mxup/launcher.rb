# frozen_string_literal: true

require 'fileutils'
require 'shellwords'

module Mxup
  # Generates and manages per-window launcher scripts.
  #
  # Each declared window with non-trivial content (setup snippet, wait_for,
  # env vars, or a command) gets a launcher script at
  #   ~/.local/share/mxup/<session>/<window>_launcher.sh
  #
  # The keys sent to tmux are simply ". <path>", so we can rewrite the script
  # on every `mxup up` without having to re-send anything to healthy panes.
  class Launcher
    def initialize(config, runtime_root: RUNTIME_DIR)
      @config       = config
      @runtime_root = runtime_root
    end

    def session_runtime_dir
      File.join(@runtime_root, @config.session)
    end

    def script_path(window_name)
      File.join(session_runtime_dir, "#{window_name}_launcher.sh")
    end

    # Returns the shell keys to send to a fresh pane for this window. Empty
    # string for a window that has nothing to execute (bare interactive shell).
    def command_for(window)
      content?(window) ? ". #{script_path(window.name)}" : ''
    end

    # Materialise launcher scripts for every window that needs one. Safe to
    # call repeatedly; overwrites existing files.
    def write_all
      FileUtils.mkdir_p(session_runtime_dir)
      @config.windows.each do |win|
        next unless content?(win)
        path = script_path(win.name)
        File.write(path, build_script(win))
        File.chmod(0o755, path)
      end
    end

    def cleanup
      dir = session_runtime_dir
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end

    # Build (but don't write) the shell text for a window's launcher script.
    # Exposed for inspection/tests; production callers use #write_all.
    def build_script(window)
      sections = []
      sections << "# mxup launcher for #{window.name}"
      sections << "cd #{Shellwords.escape(window.root)}"

      if @config.setup && !@config.setup.empty?
        sections << ''
        @config.setup.split("\n").each { |l| sections << l }
      end

      if window.wait_for
        sections << ''
        sections.concat(build_wait_block(window.wait_for))
      end

      if window.env.any?
        sections << ''
        window.env.each { |k, v| sections << "export #{k}=#{Shellwords.escape(v)}" }
      end

      if window.command && !window.command.empty?
        sections << ''
        sections << window.command
      end

      sections.join("\n") + "\n"
    end

    # Shell snippet (array of lines) implementing a wait_for check.
    def build_wait_block(spec)
      check = probe_for(spec)
      lines = []
      lines << "echo 'Waiting for #{spec.label}...'"
      lines << "_mxup_wait_start=$(date +%s)"
      lines << ''

      if spec.timeout
        lines << "until #{check}; do"
        lines << "  _mxup_elapsed=$(($(date +%s) - _mxup_wait_start))"
        lines << "  if [ \"$_mxup_elapsed\" -ge #{spec.timeout.to_i} ]; then"
        lines << "    echo 'Timed out waiting for #{spec.label} after #{spec.timeout.to_i}s' >&2"
        lines << '    break'
        lines << '  fi'
        lines << "  echo \"  still waiting... (${_mxup_elapsed}s of #{spec.timeout.to_i}s)\""
        lines << "  sleep #{spec.interval}"
        lines << 'done'
      else
        lines << "until #{check}; do"
        lines << "  echo \"  still waiting... ($(($(date +%s) - _mxup_wait_start))s)\""
        lines << "  sleep #{spec.interval}"
        lines << 'done'
      end

      lines << ''
      lines << "echo '#{spec.label} is ready.'"
      lines
    end

    private

    def content?(window)
      (@config.setup && !@config.setup.empty?) ||
        window.wait_for ||
        window.env.any? ||
        (window.command && !window.command.empty?)
    end

    def probe_for(spec)
      case spec.type
      when :tcp
        host, port = spec.target.split(':', 2)
        "nc -z #{host} #{port} 2>/dev/null"
      when :http
        "curl -sf #{Shellwords.escape(spec.target)} >/dev/null 2>&1"
      when :path
        "[ -e #{Shellwords.escape(spec.target)} ]"
      when :script
        spec.target
      end
    end
  end
end
