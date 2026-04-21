# frozen_string_literal: true

require 'yaml'
require 'set'

module Mxup
  # Parsed mxup YAML config. Pure data; no tmux or filesystem side effects.
  class Config
    attr_reader :session, :setup, :windows, :layouts, :layout_names

    def initialize(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      @session = raw.fetch('session')
      @setup   = raw['setup']&.strip
      @windows = parse_windows(raw.fetch('windows'))
      @layouts, @layout_names = parse_layouts(raw['layouts'])
    end

    def default_layout
      @layout_names.first
    end

    def groups_for(layout_name)
      return [] if layout_name.nil?
      @layouts.fetch(layout_name)
    end

    # Returns an ordered list of entries describing how windows should appear
    # in tmux under the given layout. Each entry is one of:
    #   { type: :group,      name: <group name>, group: PaneGroup }
    #   { type: :standalone, name: <window name> }
    def effective_window_order(layout_name)
      groups  = groups_for(layout_name)
      grouped = groups.flat_map(&:window_names).to_set
      entries = groups.map { |g| { type: :group, name: g.name, group: g } }
      @windows.each do |w|
        entries << { type: :standalone, name: w.name } unless grouped.include?(w.name)
      end
      entries
    end

    def window_by_name(name)
      @windows.find { |w| w.name == name }
    end

    # Returns [group, index_within_group] or nil.
    def find_group_for_window(layout_name, window_name)
      groups_for(layout_name).each do |g|
        idx = g.window_names.index(window_name)
        return [g, idx] if idx
      end
      nil
    end

    private

    def parse_windows(hash)
      hash.map do |name, opts|
        opts ||= {}
        Window.new(
          name:     name,
          root:     File.expand_path(opts.fetch('root')),
          command:  opts['command']&.strip,
          env:      opts['env'] || {},
          wait_for: WaitSpec.parse(opts['wait_for'])
        )
      end
    end

    def parse_layouts(raw)
      return [{}, []] if raw.nil?

      valid_windows = @windows.map(&:name).to_set
      layouts = {}
      order   = []

      raw.each do |layout_name, groups_hash|
        order << layout_name
        groups_hash ||= {}
        seen   = Set.new
        groups = []

        groups_hash.each do |group_name, group_opts|
          group_opts ||= {}
          pane_names = Array(group_opts['panes'])

          pane_names.each do |pn|
            unless valid_windows.include?(pn)
              raise ArgumentError,
                    "Layout '#{layout_name}': window '#{pn}' not found in windows"
            end
            if seen.include?(pn)
              raise ArgumentError,
                    "Layout '#{layout_name}': window '#{pn}' appears in multiple groups"
            end
            seen << pn
          end

          groups << PaneGroup.new(
            name:         group_name,
            window_names: pane_names,
            split:        group_opts['split'] || 'tiled'
          )
        end

        layouts[layout_name] = groups
      end

      [layouts, order]
    end
  end

  Window    = Struct.new(:name, :root, :command, :env, :wait_for, keyword_init: true)
  PaneGroup = Struct.new(:name, :window_names, :split,           keyword_init: true)

  # A readiness check attached to a window.
  WaitSpec = Struct.new(:type, :target, :timeout, :interval, :label, keyword_init: true) do
    CHECK_TYPES = %w[tcp http path script].freeze

    def self.parse(raw)
      case raw
      when nil
        nil
      when String
        new(type: :tcp, target: raw, timeout: nil, interval: 2, label: raw)
      when Hash
        found = CHECK_TYPES & raw.keys
        unless found.size == 1
          raise ArgumentError,
                "wait_for must specify exactly one of: #{CHECK_TYPES.join(', ')}"
        end
        type          = found.first
        target        = raw[type]
        default_label = type == 'script' ? 'readiness check' : target
        new(
          type:     type.to_sym,
          target:   target,
          timeout:  raw['timeout'],
          interval: raw['interval'] || 2,
          label:    raw['label'] || default_label
        )
      else
        raise ArgumentError, "wait_for must be a string or hash, got #{raw.class}"
      end
    end
  end
end
