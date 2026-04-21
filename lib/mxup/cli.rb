# frozen_string_literal: true

require 'optparse'

module Mxup
  # Argv parser + dispatch. Keeps parsing rules in one place; the actual
  # behaviour lives in Runner and the focused modules it drives.
  class CLI
    COMMANDS = %w[up status down restart layout target exec].freeze

    def run(argv)
      args, options = parse(argv.dup)
      command       = extract_command(args)
      dispatch(command, args, options)
    end

    private

    def parse(args)
      options = {
        dry_run: false, config: nil, lines: nil, layout: nil,
        target: nil,    timeout: nil, force: false, quiet: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: mxup [command] [name] [options]'
        opts.on('-f', '--file FILE', 'Config file path')              { |f| options[:config]  = f }
        opts.on('--dry-run', 'Preview changes without applying')      { options[:dry_run] = true }
        opts.on('--lines N', Integer, 'Output lines (status/exec)')   { |n| options[:lines]   = n }
        opts.on('--layout NAME', 'Layout to use (for up/layout)')     { |l| options[:layout]  = l }
        opts.on('-t', '--target TARGET',
                'Target window/pane for exec (e.g. name:window)')     { |t| options[:target]  = t }
        opts.on('--timeout N', Integer, 'Timeout in seconds (exec)')  { |n| options[:timeout] = n }
        opts.on('--force', 'Force exec on a busy pane')               { options[:force] = true }
        opts.on('-q', '--quiet', 'Suppress captured output (exec)')   { options[:quiet] = true }
        opts.on('-v', '--version', 'Show version') { puts "mxup #{VERSION}"; exit }
        opts.on('-h', '--help',    'Show help')    { puts opts; exit }
      end

      parser.parse!(args)
      [args, options]
    end

    # Peek at the first non-file positional; if it's a recognised command,
    # pop it. Otherwise default to "up".
    def extract_command(args)
      first = args.first
      return 'up' if first.nil?
      return 'up' if first.include?('.yml') || first.include?('/')

      COMMANDS.include?(first) ? args.shift : 'up'
    end

    def dispatch(command, args, options)
      case command
      when 'up', 'status', 'down'       then run_basic(command, args, options)
      when 'restart', 'target'          then run_restart_or_target(command, args, options)
      when 'layout'                     then run_layout(args, options)
      when 'exec'                       then run_exec(args, options)
      else
        abort "Unknown command: #{command}. Use: #{COMMANDS.join(', ')}"
      end
    end

    def run_basic(command, args, options)
      name   = args.shift
      runner = build_runner(options, name)
      case command
      when 'up'     then runner.up
      when 'status' then runner.status(lines: options[:lines] || 2)
      when 'down'   then runner.down
      end
    end

    def run_restart_or_target(command, args, options)
      name, window_names = split_restart_spec(args, options)
      runner = build_runner(options, name)

      if command == 'restart'
        runner.restart(window_names)
      else
        runner.target(window_names)
      end
    end

    def run_layout(args, options)
      name          = args.shift
      target_layout = args.shift
      runner        = build_runner(options, name)
      target_layout ? runner.switch_layout(target_layout) : runner.show_layouts
    end

    def run_exec(args, options)
      target = options[:target] || args.shift
      abort 'Usage: mxup exec -t [name:]WINDOW "command"' if target.nil? || target.empty?

      command_str = args.shift
      abort 'Usage: mxup exec -t [name:]WINDOW "command"' if command_str.nil?

      name = target.include?(':') ? target.split(':', 2).first : nil
      build_runner(options, name).exec(
        target, command_str,
        lines: options[:lines] || 50,
        timeout: options[:timeout],
        force: options[:force],
        quiet: options[:quiet]
      )
    end

    # Parse the first positional of `restart` / `target`. Supports:
    #   "session:win1,win2"   → explicit session + window list
    #   "session"             → session name, no windows (if it resolves to a config)
    #   "win1"                → bare window name (no session prefix)
    def split_restart_spec(args, options)
      spec = args.shift
      if spec.nil?
        return [nil, []]
      elsif spec.include?(':')
        name, windows_str = spec.split(':', 2)
        return [name, windows_str ? windows_str.split(',') : []]
      end

      # Ambiguous: is `spec` a config name or a window name?
      looks_like_config = File.exist?(File.join(CONFIG_DIR, "#{spec}.yml")) ||
                          (options[:config] && spec !~ /,/)
      return [spec, args] if looks_like_config
      [nil, [spec] + args]
    end

    def build_runner(options, name)
      config = load_config(options[:config], name)
      Runner.new(config, dry_run: options[:dry_run], layout: options[:layout])
    end

    def load_config(explicit_path, name)
      path = resolve_config(explicit_path, name)
      abort "Config not found. Provide -f path or place config in #{CONFIG_DIR}/" unless path
      Config.new(path)
    end

    # Config resolution order:
    #   1. explicit -f path
    #   2. ~/.config/mxup/<name>.yml
    #   3. ./mxup.yml
    #   4. sole *.yml in ~/.config/mxup/
    def resolve_config(explicit, name)
      return explicit if explicit && File.exist?(explicit)

      if name
        candidate = File.join(CONFIG_DIR, "#{name}.yml")
        return candidate if File.exist?(candidate)
      end

      local = File.join(Dir.pwd, 'mxup.yml')
      return local if File.exist?(local)

      if Dir.exist?(CONFIG_DIR)
        configs = Dir.glob(File.join(CONFIG_DIR, '*.yml'))
        return configs.first if configs.size == 1
      end

      nil
    end
  end
end
