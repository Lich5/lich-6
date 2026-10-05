# frozen_string_literal: true

module Lich
  module WebUI
    # Host workers must not inherit a script's kill-on-exit thread group. Gate
    # execution until ownership is transferred, including any child workers.
    module HostThread
      def self.start(*arguments, &work)
        gate = Queue.new
        worker = Thread.new { gate.pop; work.call(*arguments) }
        begin
          ThreadGroup::Default.add(worker)
          gate << true
          worker
        # Even an interrupt during transfer must not strand a gated worker.
        rescue Exception # rubocop:disable Lint/RescueException
          worker.kill
          raise
        end
      end
    end
  end
end
