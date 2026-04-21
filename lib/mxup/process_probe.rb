# frozen_string_literal: true

module Mxup
  # Walks the process tree from a pane PID down to the interesting leaf, and
  # reads `ps` fields from an arbitrary pid. Used by StatusView to show the
  # actual command the user cares about (not the `zsh -c` wrapping it).
  module ProcessProbe
    module_function

    # Follow pgrep -P down the descendant tree until a leaf (no children) is
    # reached. Falls back to the starting pid if pgrep is unavailable.
    def leaf_pid(pid)
      current = pid
      loop do
        child = `pgrep -P #{current} 2>/dev/null`.strip.split("\n").first
        break if child.nil? || child.empty?
        current = child.to_i
      end
      current
    end

    def ps_field(pid, field)
      val = `ps -p #{pid} -o #{field}= 2>/dev/null`.strip
      val.empty? ? nil : val
    end
  end
end
