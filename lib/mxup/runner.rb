# frozen_string_literal: true

module Mxup
  # Public programmatic API. Composes the focused helpers — nothing here
  # should contain real business logic, only wiring and delegation.
  class Runner
    # Delay (seconds) between the two Ctrl-C presses during a restart, and
    # between Ctrl-C and sending the new command. In production 1s is enough
    # to let the pane's shell redraw its prompt; tests shorten this to avoid
    # paying multi-second waits for a purely cosmetic settle.
    DEFAULT_INTERRUPT_DELAY = 1.0

    class << self
      attr_writer :interrupt_delay

      def interrupt_delay
        @interrupt_delay || DEFAULT_INTERRUPT_DELAY
      end
    end

    def initialize(config, dry_run: false, layout: nil)
      @config  = config
      @session = config.session
      @dry_run = dry_run
      @layout  = layout
    end

    # --- primary commands --------------------------------------------------

    def up
      reconciler.up
    end

    def status(lines:)
      status_view.render(lines: lines)
    end

    def down
      unless Tmux.has_session?(@session)
        $stdout.puts "Session #{@session} is not running."
        return
      end

      if @dry_run
        $stdout.puts "[dry-run] Would gracefully stop session #{@session}"
        return
      end

      graceful_stop.call
      Tmux.kill_session(@session)
      launcher.cleanup
      $stdout.puts "Session #{@session} killed."
    end

    def restart(window_names)
      abort "Session #{@session} is not running." unless Tmux.has_session?(@session)
      launcher.write_all unless @dry_run

      targets = resolve_restart_targets(window_names)

      targets.each do |win|
        target_ref = resolver.pane_target(win.name)
        if target_ref
          restart_existing(win, target_ref)
        else
          create_missing(win)
        end
      end
    end

    def switch_layout(target_layout)
      layout_manager.switch(target_layout)
    end

    def show_layouts
      layout_manager.show(
        active: Tmux.has_session?(@session) ? resolver.stored_layout : nil
      )
    end

    def target(window_names)
      abort "Session #{@session} is not running." unless Tmux.has_session?(@session)

      requested = Array(window_names).flat_map { |n| n.split(',') }.reject(&:empty?)

      if requested.empty?
        print_all_targets
      else
        print_requested_targets(requested)
      end
    end

    def exec(target_spec, command, lines: 50, timeout: nil, force: false, quiet: false)
      exec_runner.run(target_spec, command,
                      lines: lines, timeout: timeout,
                      force: force, quiet: quiet)
    end

    private

    # --- restart helpers ---------------------------------------------------

    def resolve_restart_targets(names)
      return @config.windows if names.nil? || names.empty?

      names.flat_map { |n| n.split(',') }.map do |n|
        @config.windows.find { |w| w.name == n } ||
          abort("Window '#{n}' not found in config.")
      end
    end

    def restart_existing(win, target_ref)
      if @dry_run
        $stdout.puts "[dry-run] Would restart #{win.name}"
        return
      end
      # Two C-c's handle both "foreground is command" and "foreground is a
      # sub-prompt waiting on input"; the sleep gives the shell time to redraw.
      delay = Runner.interrupt_delay
      Tmux.send_interrupt(@session, target_ref)
      sleep delay
      Tmux.send_interrupt(@session, target_ref)
      sleep delay
      Tmux.send_keys(@session, target_ref, launcher.command_for(win))
      $stdout.puts "  #{win.name}: restarted"
    end

    def create_missing(win)
      if @dry_run
        $stdout.puts "[dry-run] Would create #{win.name}"
      else
        Tmux.new_window(@session, win.name, win.root)
        Tmux.set_pane_title(@session, win.name, 0, win.name)
        Tmux.send_keys(@session, win.name, launcher.command_for(win))
        $stdout.puts "  #{win.name}: created"
      end
    end

    # --- target helpers ----------------------------------------------------

    def print_all_targets
      @config.windows.each do |win|
        t = resolver.pane_target(win.name)
        $stdout.puts(t ? "#{win.name}\t#{@session}:#{t}" : "#{win.name}\t(not running)")
      end
    end

    def print_requested_targets(requested)
      requested.each do |wn|
        @config.windows.find { |w| w.name == wn } ||
          abort("Window '#{wn}' not found in config.")

        t = resolver.pane_target(wn)
        abort("Window '#{wn}' is not currently in the session.") unless t

        if requested.size == 1
          $stdout.puts "#{@session}:#{t}"
        else
          $stdout.puts "#{wn}\t#{@session}:#{t}"
        end
      end
    end

    # --- lazily-built collaborators ---------------------------------------

    def resolver
      @resolver ||= PaneResolver.new(@config, session: @session, layout_override: @layout)
    end

    def launcher
      @launcher ||= Launcher.new(@config)
    end

    def layout_manager
      @layout_manager ||= LayoutManager.new(
        @config, session: @session, dry_run: @dry_run, resolver: resolver
      )
    end

    def reconciler
      @reconciler ||= Reconciler.new(
        @config,
        launcher: launcher, resolver: resolver,
        layout_manager: layout_manager, dry_run: @dry_run
      )
    end

    def status_view
      @status_view ||= StatusView.new(@config, resolver: resolver)
    end

    def exec_runner
      @exec_runner ||= ExecRunner.new(@config, resolver: resolver, dry_run: @dry_run)
    end

    def graceful_stop
      @graceful_stop ||= GracefulStop.new(@session)
    end

    # --- backward-compat shims (referenced by the unit tests) -------------

    # These delegate to the launcher / layout manager so tests that poke at
    # Runner's internals via .send(:...) keep working unchanged.
    def assemble_command(win)
      launcher.command_for(win)
    end

    def write_launcher_scripts
      launcher.write_all
    end

    def launcher_script_path(name)
      launcher.script_path(name)
    end

    def session_runtime_dir
      launcher.session_runtime_dir
    end

    def cleanup_runtime_dir
      launcher.cleanup
    end

    def generate_wait_block(_name, spec)
      launcher.build_wait_block(spec)
    end
  end
end
