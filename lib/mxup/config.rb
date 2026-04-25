# frozen_string_literal: true

require 'yaml'
require 'set'

module Mxup
  # Parsed mxup YAML config. Pure data; no tmux or filesystem side effects.
  #
  # Profiles (optional): a config may declare a `profiles:` map where each
  # entry is a partial override on top of the base `setup`, `windows`, and
  # `layouts`. A single active profile is resolved at parse time and its
  # overrides are merged in before the rest of the Config is built — so the
  # rest of the system (Launcher, Reconciler, StatusView…) never has to know
  # about profiles.
  class Config
    attr_reader :session, :setup, :windows, :layouts, :layout_names,
                :profile, :profile_names, :default_profile

    def initialize(path, profile: nil)
      raw = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
      resolve_profile!(raw, profile)
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

    # Pick the active profile (if any) and merge its overrides into `raw`.
    # Sets @profile / @profile_names / @default_profile.
    def resolve_profile!(raw, requested)
      profiles = raw['profiles'] || {}
      @profile_names    = profiles.keys
      @default_profile  = raw['default_profile'] || @profile_names.first

      if profiles.empty?
        if requested
          raise ArgumentError,
                "--profile '#{requested}' was given, but this config declares no profiles"
        end
        @profile = nil
        return
      end

      @profile = requested || @default_profile
      unless profiles.key?(@profile)
        raise ArgumentError,
              "Unknown profile '#{@profile}' (available: #{@profile_names.join(', ')})"
      end

      apply_profile_overrides!(raw, profiles.fetch(@profile))
    end

    def apply_profile_overrides!(raw, override)
      return unless override.is_a?(Hash)

      if override.key?('session')
        raise ArgumentError,
              "Profile '#{@profile}' cannot override 'session'; profiles of the " \
              'same group must share one tmux session name'
      end

      raw['setup']   = override['setup']   if override.key?('setup')
      raw['layouts'] = override['layouts'] if override.key?('layouts')

      removed = []
      (override['windows'] || {}).each do |wname, woverride|
        raw['windows'] ||= {}
        if woverride.nil?
          # Explicit null ("dev-kit: ~") drops this window for this profile.
          # `parse_windows` skips absent keys; `prune_layouts!` keeps layouts
          # from referencing the now-missing name.
          raw['windows'].delete(wname)
          removed << wname
        else
          base = raw['windows'][wname] || {}
          raw['windows'][wname] = merge_window(base, woverride)
        end
      end

      prune_layouts!(raw, removed) if removed.any?
    end

    # Strip any removed window names from layout groups so parse_layouts
    # doesn't raise "window not found". A group whose panes list becomes
    # empty is dropped from the layout entirely.
    def prune_layouts!(raw, removed)
      return unless raw['layouts'].is_a?(Hash)
      removed_set = removed.to_set

      raw['layouts'].each_value do |layout_def|
        next unless layout_def.is_a?(Hash)
        layout_def.reject! do |_group_name, group_def|
          next false unless group_def.is_a?(Hash) && group_def['panes'].is_a?(Array)
          group_def['panes'] -= removed_set.to_a
          group_def['panes'].empty?
        end
      end
    end

    # Shallow merge with a special case: `env` is itself a hash that should
    # be merged (so a profile can tweak one key without redeclaring the rest).
    def merge_window(base, override)
      base.merge(override) do |key, base_val, prof_val|
        if key == 'env' && base_val.is_a?(Hash) && prof_val.is_a?(Hash)
          base_val.merge(prof_val)
        else
          prof_val
        end
      end
    end

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
