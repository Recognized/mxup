# frozen_string_literal: true

module Mxup
  # Applies / switches tmux layouts without killing processes.
  #
  # switch_layout is a three-step operation:
  #   1. Flatten any multi-pane windows back to standalone windows (break-pane)
  #   2. Re-group windows per the target layout (join-pane + select-layout)
  #   3. Reorder the windows to match config order
  class LayoutManager
    def initialize(config, session: config.session, dry_run: false,
                   resolver: PaneResolver.new(config, session: session),
                   out: nil)
      @config       = config
      @session      = session
      @dry_run      = dry_run
      @resolver     = resolver
      @out_override = out
    end

    def out
      @out_override || $stdout
    end

    def show(active: @resolver.stored_layout)
      if @config.layout_names.empty?
        out.puts 'No layouts defined in config.'
        return
      end

      out.puts 'Available layouts:'
      @config.layout_names.each do |name|
        marker = name == active ? ' (active)' : ''
        groups = @config.groups_for(name)
        if groups.empty?
          out.puts "  #{name}#{marker}: flat (all standalone)"
        else
          desc = groups.map { |g| "#{g.name}=[#{g.window_names.join(',')}]" }.join(', ')
          out.puts "  #{name}#{marker}: #{desc}"
        end
      end
    end

    def switch(target_layout)
      unless Tmux.has_session?(@session)
        abort "Session #{@session} is not running."
      end
      unless @config.layout_names.include?(target_layout)
        abort "Layout '#{target_layout}' not found in config. " \
              "Available: #{@config.layout_names.join(', ')}"
      end

      current = @resolver.stored_layout
      if current == target_layout
        out.puts "Already using layout '#{target_layout}'."
        return
      end

      if @dry_run
        out.puts "[dry-run] Would switch layout from '#{current}' to '#{target_layout}'"
        return
      end

      out.puts "Switching layout: #{current || 'none'} → #{target_layout}..."
      flatten_to_standalone
      apply(target_layout)
      reorder(target_layout)
      Tmux.set_environment(@session, 'MXUP_LAYOUT', target_layout)
      out.puts "Layout switched to '#{target_layout}'."
    end

    # Collapse every multi-pane window into individual standalone windows.
    # Run before applying a new layout to start from a clean state.
    def flatten_to_standalone
      multi = Tmux.list_panes(@session)
                  .group_by { |p| p[:name] }
                  .select   { |_, ps| ps.size > 1 }

      multi.each do |win_name, panes|
        sorted = panes.sort_by { |p| p[:pane_index] }.reverse

        sorted.each do |pane|
          next if pane[:pane_index].zero?
          logical = pane[:title].to_s.empty? \
            ? "#{win_name}_#{pane[:pane_index]}" \
            : pane[:title]
          Tmux.break_pane(@session, win_name, pane[:pane_index], logical)
        end

        first = sorted.last
        first_logical = first[:title].to_s.empty? ? win_name : first[:title]
        Tmux.rename_window(@session, win_name, first_logical) if first_logical != win_name
      end
    end

    # Apply a named layout to a session whose windows are currently all standalone.
    def apply(layout_name)
      groups = @config.groups_for(layout_name)

      groups.each do |group|
        next if group.window_names.size < 2

        first_wn = group.window_names.first
        Tmux.rename_window(@session, first_wn, group.name)

        group.window_names.drop(1).each do |wn|
          Tmux.join_pane(@session, wn, group.name)
        end

        group.window_names.each_with_index do |wn, idx|
          Tmux.set_pane_title(@session, group.name, idx, wn)
        end
        Tmux.select_layout(@session, group.name, group.split)
      end

      # Single-window "groups" still get their window renamed to the group name
      # so that subsequent lookups (status, target) find them.
      groups.select { |g| g.window_names.size == 1 }.each do |group|
        wn = group.window_names.first
        Tmux.rename_window(@session, wn, group.name)
        Tmux.set_pane_title(@session, group.name, 0, wn)
      end
    end

    # Move windows so their tmux indices match the order declared in config.
    # Two-phase to avoid collisions: first park everyone in a high-index scratch
    # zone, then move them into their final slots.
    def reorder(layout_name = @resolver.active_layout)
      return if @dry_run

      order = @config.effective_window_order(layout_name)
      names = order.map { |e| e[:name] }

      names.each_with_index do |name, i|
        cur = Tmux.list_windows(@session).find { |w| w[:name] == name }
        next unless cur
        Tmux.move_window(@session, name, 900 + i)
      end

      names.each_with_index do |name, target_idx|
        Tmux.move_window(@session, name, target_idx)
      end
    end
  end
end
