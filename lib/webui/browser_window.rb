# frozen_string_literal: true

require_relative 'browser_launcher'

module Lich
  module WebUI
    # One isolated browser app process per page. Only its PID may be terminated;
    # closing a page never terminates the shared browser or WebUI server.
    class BrowserWindow
      def initialize(on_close:, opener: nil, terminate: Process.method(:kill))
        @opener = opener || BrowserLauncher.method(:open)
        @terminate = terminate
        @on_close = on_close
        @mutex = Mutex.new
        @closed = false
        @pid = nil
      end

      def open(url, geometry: nil)
        result = @opener.call(url, geometry: geometry, on_start: method(:started), on_exit: method(:exited))
        close unless result
        result
      rescue StandardError
        close
        raise
      end

      def close
        @mutex.synchronize do
          @closed = true
          terminate_process
        end
      end

      private

      # Closing while spawn is still in progress also closes the arriving PID.
      def started(pid)
        @mutex.synchronize do
          @pid = pid
          terminate_process if @closed
        end
      end

      def exited
        notify = @mutex.synchronize do
          @pid = nil
          next false if @closed

          @closed = true
          true
        end
        @on_close.call if notify
      end

      def terminate_process
        return unless @pid

        @terminate.call('TERM', @pid)
        @pid = nil
      rescue Errno::ESRCH, Errno::ECHILD
        @pid = nil
      end
    end
  end
end
