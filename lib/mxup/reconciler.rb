# frozen_string_literal: true

module Mxup
  # Drives `mxup up`: creates a session from scratch when missing, or brings
  # the existing session in line with the config.
  #
  # Reconciliation rules:
  #   - missing windows   → create + start command
  #   - extra windows     → kill (with warning)
  #   - idle/crashed      → re-send the command
  #   - running healthy   → leave alone
  #   - layout changed    → regroup panes without killing PIDs
  class Reconciler
    def initialize(config, launcher:, resolver:, layout_manager:,
                   dry_run: false, out: nil, err: nil)
      @config         = config
      @session        = config.session
      @launcher       = launcher
      @resolver       = resolver
      @layout_manager = layout_manager
      @dry_run        = dry_run
      @out_override   = out
      @err_override   = err
    end

    def out
      @out_override || $stdout
    end

    def err
      @err_override || $stderr
    end

    def up
      if Tmux.has_session?(@session)
        reconcile
      else
        create_fresh
      end
    end

    private

    def create_fresh
      out.puts "Creating session #{@session}..."
      @launcher.write_all unless @dry_run

      layout = @resolver.active_layout
      order  = @config.effective_window_order(layout)

      if @dry_run
        order.each do |entry|
          if entry[:type] == :group
            names = entry[:group].window_names.join(', ')
            out.puts "[dry-run] Would create pane group: #{entry[:name]} (#{names})"
          else
            out.puts "[dry-run] Would create window: #{entry[:name]}"
          end
        end
        return
      end

      create_first_entry(order.first)
      order.drop(1).each { |entry| create_entry(entry) }

      Tmux.set_environment(@session, 'MXUP_LAYOUT', layout) if layout
      Tmux.set_environment(@session, 'MXUP_PROFILE', @config.profile) if @config.profile
      out.puts "Session #{@session} is up (#{@config.windows.size} windows)."
    end

    def create_first_entry(entry)
      if entry[:type] == :group
        group     = entry[:group]
        first_win = @config.window_by_name(group.window_names.first)
        Tmux.new_session(@session, group.name, first_win.root)
        populate_pane_group_in_existing_window(group)
        out.puts "  #{group.name}: created (#{group.window_names.join(', ')})"
      else
        win = @config.window_by_name(entry[:name])
        Tmux.new_session(@session, win.name, win.root)
        Tmux.set_pane_title(@session, win.name, 0, win.name)
        Tmux.send_keys(@session, win.name, @launcher.command_for(win))
        out.puts "  #{win.name}: created"
      end
    end

    def create_entry(entry)
      if entry[:type] == :group
        create_pane_group(entry[:group])
        out.puts "  #{entry[:name]}: created (#{entry[:group].window_names.join(', ')})"
      else
        win = @config.window_by_name(entry[:name])
        create_standalone(win)
        out.puts "  #{win.name}: created"
      end
    end

    def reconcile
      out.puts "Reconciling session #{@session}..."
      @launcher.write_all unless @dry_run

      layout = @resolver.active_layout
      stored = Tmux.show_environment(@session, 'MXUP_LAYOUT')

      @layout_manager.switch(layout) if layout && stored && stored != layout

      existing_panes   = Tmux.list_panes(@session)
      existing_windows = Tmux.list_windows(@session).map { |w| w[:name] }
      order            = @config.effective_window_order(layout)

      remove_extras(existing_windows, order)
      order.each { |entry| reconcile_entry(entry, existing_panes, existing_windows) }

      @layout_manager.reorder(layout) unless @dry_run
      Tmux.set_environment(@session, 'MXUP_LAYOUT', layout) if layout && !@dry_run
      Tmux.set_environment(@session, 'MXUP_PROFILE', @config.profile) if @config.profile && !@dry_run
      out.puts 'Reconciliation complete.'
    end

    def remove_extras(existing_windows, order)
      expected = order.map { |e| e[:name] }.to_set
      existing_windows.reject { |n| expected.include?(n) }.each do |name|
        if @dry_run
          out.puts "  [dry-run] Would remove extra window: #{name}"
        else
          err.puts "  #{name}: not in config — removing"
          Tmux.kill_window(@session, name)
        end
      end
    end

    def reconcile_entry(entry, panes, windows)
      if entry[:type] == :group
        reconcile_group(entry[:group], panes, windows)
      else
        reconcile_standalone(entry[:name], panes)
      end
    end

    def reconcile_group(group, panes, windows)
      unless windows.include?(group.name)
        if @dry_run
          out.puts "  [dry-run] Would create pane group: #{group.name}"
        else
          create_pane_group(group)
          out.puts "  #{group.name}: created (#{group.window_names.join(', ')})"
        end
        return
      end

      expected = group.window_names.size
      current  = Tmux.pane_count(@session, group.name)
      if current != expected
        if @dry_run
          out.puts "  [dry-run] Would recreate pane group: #{group.name} " \
                    "(pane count #{current} != #{expected})"
        else
          Tmux.kill_window(@session, group.name)
          create_pane_group(group)
          out.puts "  #{group.name}: recreated (pane count changed)"
        end
        return
      end

      group_panes = panes.select { |p| p[:name] == group.name }
                         .sort_by { |p| p[:pane_index] }

      group.window_names.each_with_index do |wn, idx|
        win  = @config.window_by_name(wn)
        pane = group_panes.find { |p| p[:title] == wn } ||
               group_panes.find { |p| p[:pane_index] == idx }
        next unless pane

        actual_idx = pane[:pane_index]
        target     = Tmux.pane_target(group.name, actual_idx)

        if SHELLS.include?(pane[:fg_cmd])
          if @dry_run
            out.puts "  [dry-run] Would restart idle pane: #{wn} in #{group.name}"
          else
            Tmux.send_keys(@session, target, @launcher.command_for(win))
            out.puts "  #{wn}: restarted (was idle) [#{group.name}.#{actual_idx}]"
          end
        else
          out.puts "  #{wn}: running (#{pane[:fg_cmd]}) — ok [#{group.name}.#{actual_idx}]"
        end
      end
    end

    def reconcile_standalone(window_name, panes)
      win  = @config.window_by_name(window_name)
      pane = panes.find { |p| p[:name] == window_name }

      if pane.nil?
        if @dry_run
          out.puts "  [dry-run] Would create missing window: #{window_name}"
        else
          create_standalone(win)
          out.puts "  #{window_name}: created (was missing)"
        end
      elsif SHELLS.include?(pane[:fg_cmd])
        if @dry_run
          out.puts "  [dry-run] Would restart idle window: #{window_name}"
        else
          Tmux.send_keys(@session, window_name, @launcher.command_for(win))
          out.puts "  #{window_name}: restarted (was idle)"
        end
      else
        out.puts "  #{window_name}: running (#{pane[:fg_cmd]}) — ok"
      end
    end

    def create_pane_group(group)
      first_win = @config.window_by_name(group.window_names.first)
      Tmux.new_window(@session, group.name, first_win.root)
      populate_pane_group_in_existing_window(group)
    end

    def populate_pane_group_in_existing_window(group)
      group.window_names.drop(1).each_with_index do |wn, i|
        win = @config.window_by_name(wn)
        Tmux.split_window(@session, group.name, win.root, target_pane: i)
      end

      Tmux.select_layout(@session, group.name, group.split)

      group.window_names.each_with_index do |wn, idx|
        win = @config.window_by_name(wn)
        Tmux.set_pane_title(@session, group.name, idx, win.name)
        Tmux.send_keys(@session, Tmux.pane_target(group.name, idx), @launcher.command_for(win))
      end
    end

    def create_standalone(win)
      Tmux.new_window(@session, win.name, win.root)
      Tmux.set_pane_title(@session, win.name, 0, win.name)
      Tmux.send_keys(@session, win.name, @launcher.command_for(win))
    end
  end
end
