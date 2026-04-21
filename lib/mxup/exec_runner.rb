# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require 'tmpdir'
require 'timeout'

module Mxup
  # Implements `mxup exec`: send a command to a pane, block until it finishes,
  # print its output, and exit with its return code. The three interesting
  # parts are:
  #
  #   1. Resolving a logical window name to a real tmux pane target.
  #   2. Using `tmux wait-for -S <marker>` so we know the command finished.
  #   3. Capturing both the output (tmux capture-pane) and the exit code
  #      (written to a temp file by the wrapped command).
  class ExecRunner
    def initialize(config, resolver:, dry_run: false,
                   out: nil, err: nil, exiter: ->(n) { exit(n) })
      @config       = config
      @session      = config.session
      @resolver     = resolver
      @dry_run      = dry_run
      @out_override = out
      @err_override = err
      @exit         = exiter
    end

    def out
      @out_override || $stdout
    end

    def err
      @err_override || $stderr
    end

    # target_spec may be:
    #   "session:window"      — session must match config
    #   "window"              — logical name from config, or a raw tmux window
    #   "window.pane_index"   — raw tmux pane address
    def run(target_spec, command, lines: 50, timeout: nil, force: false, quiet: false)
      abort "Session #{@session} is not running." unless Tmux.has_session?(@session)
      abort 'mxup exec: command is required.' if command.nil? || command.strip.empty?

      window_part = strip_session_prefix(target_spec)
      resolved    = resolve_target(window_part)
      abort "Target '#{window_part}' not found in session '#{@session}'." unless resolved

      full_target = "#{@session}:#{resolved}"
      refuse_if_busy(resolved, full_target) unless force

      if @dry_run
        out.puts "[dry-run] Would exec on #{full_target}: #{command}"
        return 0
      end

      send_and_wait(full_target, command, lines: lines, timeout: timeout, quiet: quiet)
    end

    private

    def strip_session_prefix(spec)
      return spec unless spec.include?(':')
      sess, rest = spec.split(':', 2)
      if sess != @session
        abort "Target session '#{sess}' does not match config session '#{@session}'."
      end
      rest
    end

    def resolve_target(window_part)
      # First try: logical config window (handles group membership).
      if @config.windows.any? { |w| w.name == window_part }
        resolved = @resolver.pane_target(window_part)
        return resolved if resolved
      end

      # Explicit "window.pane_index" form — accept if the window exists.
      if window_part =~ /\A(.+)\.\d+\z/
        raw_win = Regexp.last_match(1)
        return window_part if tmux_window_names.include?(raw_win)
      end

      # Fallback: raw tmux window name that isn't in the config.
      tmux_window_names.include?(window_part) ? window_part : nil
    end

    def tmux_window_names
      Tmux.list_windows(@session).map { |w| w[:name] }
    end

    def refuse_if_busy(resolved, full_target)
      pane = @resolver.pane_for(resolved)
      return unless pane && !SHELLS.include?(pane[:fg_cmd])

      abort "Target pane #{full_target} is busy (#{pane[:fg_cmd]}). " \
            'Pass --force to send anyway.'
    end

    def send_and_wait(full_target, command, lines:, timeout:, quiet:)
      marker    = fresh_marker
      exit_file = File.join(Dir.tmpdir, "#{marker}.rc")
      FileUtils.rm_f(exit_file)

      cmd_clean = command.strip.sub(/;+\s*\z/, '')
      # Wrap in a subshell so `exit`, `set -e`, or a failing command can't
      # terminate the pane's interactive shell (which would strand us waiting
      # for the marker forever).
      wrapped = "( #{cmd_clean} ); " \
                '__mxup_rc=$?; ' \
                "echo $__mxup_rc > #{Shellwords.escape(exit_file)}; " \
                "tmux wait-for -S #{Shellwords.escape(marker)}"

      unless system("tmux send-keys -t #{Tmux.esc(full_target)} #{Shellwords.escape(wrapped)} Enter")
        abort "Failed to send command to #{full_target}."
      end

      timed_out = wait_for_marker(marker, timeout)

      output = `tmux capture-pane -t #{Tmux.esc(full_target)} -p -S -#{lines.to_i}`
      unless quiet
        out.print output
        out.puts unless output.end_with?("\n")
      end

      if timed_out
        err.puts "[mxup] exec: timed out after #{timeout}s waiting for command on #{full_target}."
        FileUtils.rm_f(exit_file)
        @exit.call(124)
        return
      end

      rc = read_exit_code(exit_file)
      FileUtils.rm_f(exit_file)
      @exit.call(rc || 0)
    end

    def wait_for_marker(marker, timeout)
      if timeout.nil?
        system("tmux wait-for #{Tmux.esc(marker)}")
        return false
      end

      pid = Process.spawn("tmux wait-for #{Tmux.esc(marker)}")
      begin
        Timeout.timeout(timeout) { Process.waitpid(pid) }
        false
      rescue Timeout::Error
        kill_waiter(pid)
        # Release anyone else still blocked on the marker.
        system("tmux wait-for -S #{Tmux.esc(marker)} 2>/dev/null")
        true
      end
    end

    def kill_waiter(pid)
      Process.kill('TERM', pid)
    rescue StandardError
      # already gone
    ensure
      begin
        Process.waitpid(pid)
      rescue StandardError
        # already reaped
      end
    end

    def read_exit_code(path)
      return nil unless File.exist?(path)
      val = File.read(path).strip
      val.empty? ? nil : val.to_i
    end

    def fresh_marker
      "mxup-exec-#{Process.pid}-#{Time.now.to_i}-#{rand(10**9)}"
    end
  end
end
