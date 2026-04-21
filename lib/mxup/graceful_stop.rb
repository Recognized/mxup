# frozen_string_literal: true

module Mxup
  # Sends SIGINT to every non-shell pane in a session, then waits for them to
  # exit. Used by `mxup down` before the final kill-session.
  class GracefulStop
    # Interval (seconds) between SIGINT rounds. Overridable for tests that
    # don't want to pay the 1s settle between retries.
    DEFAULT_ROUND_INTERVAL = 1.0

    class << self
      attr_writer :round_interval

      def round_interval
        @round_interval || DEFAULT_ROUND_INTERVAL
      end
    end

    def initialize(session, out: nil, err: nil)
      @session      = session
      @out_override = out
      @err_override = err
    end

    def out
      @out_override || $stdout
    end

    def err
      @err_override || $stderr
    end

    def call(timeout: 30)
      out.puts "Stopping session #{@session}..."
      deadline = Time.now + timeout
      round    = 0

      loop do
        break unless Tmux.has_session?(@session)

        busy = busy_panes
        break if busy.empty?

        if round.positive?
          remaining = (deadline - Time.now).ceil
          plural    = busy.size == 1 ? 'process' : 'processes'
          out.puts "  waiting... #{busy.size} #{plural} still running (#{remaining}s left)"
        end

        busy.each do |pane|
          target = Tmux.pane_target(pane[:name], pane[:pane_index])
          Tmux.send_interrupt(@session, target)
        end

        if Time.now >= deadline
          names = busy.map { |p| p[:title].to_s.empty? ? p[:name] : p[:title] }.uniq
          err.puts "  timeout: #{names.join(', ')} did not exit in #{timeout}s — killing anyway"
          break
        end

        round += 1
        sleep GracefulStop.round_interval
      end
    end

    private

    def busy_panes
      Tmux.list_panes(@session).reject { |p| SHELLS.include?(p[:fg_cmd]) }
    end
  end
end
