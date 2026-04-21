# frozen_string_literal: true

module Mxup
  # Answers the question "where is the logical window <foo> actually living
  # in tmux right now?" given the config + active layout + live tmux state.
  #
  # Separating this from Runner means Reconciler, LayoutManager, ExecRunner,
  # StatusView and Target can all share a single source of truth.
  class PaneResolver
    def initialize(config, session: config.session, layout_override: nil)
      @config          = config
      @session         = session
      @layout_override = layout_override
    end

    # The layout the caller asked for, or the one persisted in the session's
    # tmux environment, or the config's default. May be nil if no layouts at all.
    def active_layout
      return @layout_override if @layout_override
      Tmux.has_session?(@session) ? stored_layout : @config.default_layout
    end

    # Same as #active_layout but ignores any --layout override — used when we
    # need to know what's really in the session right now (e.g. to decide
    # whether a layout switch is needed).
    def stored_layout
      if Tmux.has_session?(@session)
        stored = Tmux.show_environment(@session, 'MXUP_LAYOUT')
        return stored if stored && @config.layout_names.include?(stored)
      end
      @config.default_layout
    end

    # Resolve a logical window name to a tmux target string (either "window"
    # for a standalone, or "group.pane_index" for a grouped window). Returns
    # nil if the window isn't currently in the session.
    def pane_target(window_name, layout = active_layout)
      result = @config.find_group_for_window(layout, window_name)

      if result
        group, cfg_idx = result
        return nil unless window_exists?(group.name)

        pane = Tmux.list_panes(@session)
                   .find { |p| p[:name] == group.name && p[:title] == window_name }
        actual_idx = pane ? pane[:pane_index] : cfg_idx
        Tmux.pane_target(group.name, actual_idx)
      else
        window_exists?(window_name) ? window_name : nil
      end
    end

    # Look up the pane metadata hash for an already-resolved tmux target.
    def pane_for(target)
      if target =~ /\A(.+)\.(\d+)\z/
        win_name = Regexp.last_match(1)
        pane_idx = Regexp.last_match(2).to_i
        Tmux.list_panes(@session)
            .find { |p| p[:name] == win_name && p[:pane_index] == pane_idx }
      else
        Tmux.list_panes(@session)
            .find { |p| p[:name] == target && p[:pane_index] == 0 }
      end
    end

    def window_exists?(name)
      Tmux.list_windows(@session).any? { |w| w[:name] == name }
    end
  end
end
