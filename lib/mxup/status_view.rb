# frozen_string_literal: true

require 'set'

module Mxup
  # Renders `mxup status` output.
  class StatusView
    INDENT = '    '

    def initialize(config, resolver:, out: nil)
      @config       = config
      @session      = config.session
      @resolver     = resolver
      @out_override = out
    end

    def out
      @out_override || $stdout
    end

    def render(lines:)
      unless Tmux.has_session?(@session)
        out.puts "SESSION: #{@session} — NOT RUNNING"
        out.puts "Start with: mxup up #{@session}"
        return
      end

      active       = @resolver.active_layout
      created      = Tmux.session_created(@session)
      created_at   = Time.at(created.to_i).strftime('%Y-%m-%d %H:%M:%S')
      layout_info  = active ? " (layout: #{active})" : ''
      out.puts "SESSION: #{@session} — up since #{created_at}#{layout_info}"
      out.puts

      panes           = Tmux.list_panes(@session)
      declared_names  = @config.windows.map(&:name)
      printed         = Set.new
      order           = @config.effective_window_order(active)

      order.each do |entry|
        if entry[:type] == :group
          render_group(entry[:group], panes, lines, printed)
        else
          render_standalone(entry[:name], panes, lines, declared_names, printed)
        end
      end

      render_extras(panes, lines, printed)
    end

    private

    def render_group(group, panes, lines, printed)
      group_panes = panes.select { |p| p[:name] == group.name }
                         .sort_by { |p| p[:pane_index] }

      if group_panes.empty?
        group.window_names.each do |wn|
          out.puts "[?] #{wn}  MISSING (group: #{group.name})"
          out.puts
        end
        return
      end

      header_idx = group_panes.first[:window_index]
      out.puts "[#{header_idx}] #{group.name} " \
                "(#{group.window_names.join(', ')})  split=#{group.split}"

      group.window_names.each_with_index do |wn, idx|
        printed << wn
        pane = group_panes.find { |p| p[:title] == wn } ||
               group_panes.find { |p| p[:pane_index] == idx }
        if pane.nil?
          out.puts "  #{wn}: MISSING"
          next
        end
        out.puts "  #{wn}:"
        print_pane(pane, wn, lines, indent: '    ')
      end
      out.puts
    end

    def render_standalone(name, panes, lines, declared, printed)
      printed << name
      pane = panes.find { |p| p[:name] == name && p[:pane_index] == 0 }
      if pane.nil?
        out.puts "[?] #{name}  MISSING"
        out.puts
        return
      end

      tag = declared.include?(pane[:name]) ? '' : ' [NOT IN CONFIG]'
      out.puts "[#{pane[:window_index]}] #{pane[:name]}#{tag}"
      print_pane(pane, name, lines, indent: INDENT)
      out.puts
    end

    # Surface any panes that weren't already printed (unexpected windows).
    def render_extras(panes, lines, printed)
      panes.each do |pane|
        logical = pane[:title].to_s.empty? ? pane[:name] : pane[:title]
        next if printed.include?(logical) || printed.include?(pane[:name])

        out.puts "[#{pane[:window_index]}] #{pane[:name]} [NOT IN CONFIG]"
        print_pane(pane, pane[:name], lines, indent: INDENT)
        out.puts
      end
    end

    def print_pane(pane, logical_name, lines, indent: INDENT)
      idle   = SHELLS.include?(pane[:fg_cmd])
      status = idle ? idle_status(pane) : running_status(pane, indent)

      in_group = pane[:name] != logical_name
      target   = in_group ? Tmux.pane_target(pane[:name], pane[:pane_index]) : pane[:name]
      out.puts "#{indent}target: #{@session}:#{target}"
      out.puts "#{indent}cwd: #{pane[:cwd]}"
      out.puts "#{indent}#{status}"

      tail = Tmux.capture_pane(@session, target)
                 .split("\n")
                 .reject { |l| l.strip.empty? }
                 .last(lines)
      return if tail.empty?

      out.puts "#{indent}--- last output (up to #{lines} lines) ---"
      tail.each { |l| out.puts "#{indent}#{l}" }
      out.puts "#{indent}---"
    end

    def idle_status(pane)
      "IDLE (shell: #{pane[:fg_cmd]}, pid=#{pane[:pid]})"
    end

    def running_status(pane, indent)
      leaf    = ProcessProbe.leaf_pid(pane[:pid])
      cmd     = ProcessProbe.ps_field(leaf, 'args') || pane[:fg_cmd]
      elapsed = ProcessProbe.ps_field(leaf, 'etime')&.strip || '?'
      started = ProcessProbe.ps_field(leaf, 'lstart') || '?'
      "RUNNING  pid=#{leaf}  elapsed=#{elapsed}  fg=#{pane[:fg_cmd]}\n" \
        "#{indent}command: #{cmd}\n" \
        "#{indent}started: #{started}"
    end
  end
end
