# frozen_string_literal: true

require 'shellwords'

module Mxup
  # Thin wrapper over the tmux(1) CLI. Every method shells out; nothing here
  # knows about mxup's own config. Kept as a module so callers can reference
  # Mxup::Tmux.list_panes(...) without instantiating anything.
  module Tmux
    module_function

    # --- inspection --------------------------------------------------------

    def has_session?(name)
      system("tmux has-session -t #{esc(name)} 2>/dev/null")
    end

    def session_created(name)
      `tmux display-message -t #{esc(name)} -p '\#{session_created}'`.strip
    end

    def list_windows(session)
      `tmux list-windows -t #{esc(session)} -F '\#{window_index}|\#{window_name}'`
        .strip.split("\n").map do |line|
          idx, name = line.split('|', 2)
          { index: idx.to_i, name: name }
        end
    end

    def list_panes(session)
      fmt = '#{window_index}|#{window_name}|#{pane_index}|#{pane_pid}|' \
            '#{pane_current_path}|#{pane_current_command}|#{pane_title}'
      `tmux list-panes -t #{esc(session)} -s -F '#{fmt}'`
        .strip.split("\n").map do |line|
          win_idx, name, pane_idx, pid, cwd, fg, title = line.split('|', 7)
          { window_index: win_idx.to_i, name: name, pane_index: pane_idx.to_i,
            pid: pid.to_i, cwd: cwd, fg_cmd: fg, title: title.to_s }
        end
    end

    def pane_count(session, window)
      `tmux list-panes -t #{esc(session)}:#{esc(window)} 2>/dev/null`
        .strip.split("\n").size
    end

    # Capture the pane's *entire* scrollback (-S - is "start of history") so
    # callers can filter and tail as they see fit. We deliberately don't pass
    # -S -N here: if the interesting output scrolled past the visible window,
    # a lower bound would silently hide it.
    def capture_pane(session, target, _lines = nil)
      `tmux capture-pane -t #{esc(session)}:#{esc(target)} -p -S - 2>/dev/null`
    end

    # --- mutation ----------------------------------------------------------

    def new_session(name, first_window_name, root)
      system("tmux new-session -d -s #{esc(name)} -n #{esc(first_window_name)} -c #{esc(root)}")
    end

    def new_window(session, name, root)
      system("tmux new-window -t #{esc(session)} -n #{esc(name)} -c #{esc(root)}")
    end

    def split_window(session, window, root, target_pane: nil)
      target = target_pane \
        ? "#{esc(session)}:#{esc(window)}.#{target_pane}" \
        : "#{esc(session)}:#{esc(window)}"
      system("tmux split-window -t #{target} -c #{esc(root)} -d")
    end

    def select_layout(session, window, layout)
      system("tmux select-layout -t #{esc(session)}:#{esc(window)} #{esc(layout)}")
    end

    def join_pane(session, src_window, dst_window)
      system("tmux join-pane -s #{esc(session)}:#{esc(src_window)} -t #{esc(session)}:#{esc(dst_window)} -d")
    end

    # Break a pane out into its own window. Without an explicit -t target,
    # tmux places the new window in the *current client's* session, which
    # would send it to whichever session the user happens to be attached to
    # (e.g. air-backend when running tests). Always pin the destination to
    # the source session.
    def break_pane(session, window, pane_index, new_window_name)
      system("tmux break-pane -s #{esc(session)}:#{esc(window)}.#{pane_index} " \
             "-t #{esc(session)}: -n #{esc(new_window_name)} -d")
    end

    def rename_window(session, old_name, new_name)
      system("tmux rename-window -t #{esc(session)}:#{esc(old_name)} #{esc(new_name)}")
    end

    def set_pane_title(session, window, pane_index, title)
      system("tmux select-pane -t #{esc(session)}:#{esc(window)}.#{pane_index} -T #{esc(title)}")
    end

    def set_environment(session, key, value)
      system("tmux set-environment -t #{esc(session)} #{esc(key)} #{esc(value)}")
    end

    # Returns the value stored in the session's environment, or nil if unset
    # (tmux prefixes unset entries with '-').
    def show_environment(session, key)
      out = `tmux show-environment -t #{esc(session)} #{esc(key)} 2>/dev/null`.strip
      return nil if out.empty? || out.start_with?('-')
      out.split('=', 2).last
    end

    def kill_window(session, name)
      system("tmux kill-window -t #{esc(session)}:#{esc(name)}")
    end

    def kill_session(name)
      system("tmux kill-session -t #{esc(name)}")
    end

    def send_keys(session, target, keys)
      system("tmux send-keys -t #{esc(session)}:#{esc(target)} #{esc(keys)} Enter")
    end

    def send_interrupt(session, target)
      system("tmux send-keys -t #{esc(session)}:#{esc(target)} C-c")
    end

    def move_window(session, src_name, dst_index)
      system("tmux move-window -s #{esc(session)}:#{esc(src_name)} -t #{esc(session)}:#{dst_index} 2>/dev/null")
    end

    def swap_window(session, idx_a, idx_b)
      system("tmux swap-window -s #{esc(session)}:#{idx_a} -t #{esc(session)}:#{idx_b}")
    end

    # --- helpers -----------------------------------------------------------

    # Format a pane target string "window.index" for use in other tmux calls.
    def pane_target(window, pane_index)
      "#{window}.#{pane_index}"
    end

    def esc(val)
      Shellwords.escape(val.to_s)
    end
  end
end
