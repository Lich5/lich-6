# frozen_string_literal: true

require 'monitor'

module Lich
  module Common
    module ScriptScope
      module Gtk
        class UnsupportedOperation < StandardError; end

        # One compatibility owner and shadow-state lock per running script.
        # Browser callbacks still execute on the core's bounded owner dispatcher.
        class Session
          attr_reader :port

          # Binds the script's shadow state and callback submissions to one host.
          # @param owner [Script] script whose lifetime governs all shim work
          def initialize(owner)
            @owner = owner
            @port = Lich::WebUI.adapter(owner: owner, viewer: self)
            @dispatch = Lich::WebUI.callback_queue(owner: owner)
            @mutex = Monitor.new
            @closed = false
            @windows = []
            @degradations = {}
            @window_viewers = {}.compare_by_identity
            notice = "#{owner.name}: legacy GTK compatibility is deprecated; convert this script to native WebUI."
            respond(notice)
            Lich.log(notice)
          end

          def synchronize(&block)
            @mutex.synchronize(&block)
          end

          # Defers script UI work without holding the shadow-state lock on admission.
          # The core worker supplies FIFO ordering and bounded cancellation; this
          # wrapper supplies Script ownership and the legacy queue error boundary.
          # Exit handlers run inline on the owner's cleanup thread because its
          # ordinary workers have already been stopped. This also permits their
          # existing queue-then-wait cleanup pattern without reviving dispatch.
          # @yield one-shot callback; must not wait for another callback on this owner
          # @return [Symbol, nil] :queued when admitted/cleaned up, nil for late work
          # @raise [ArgumentError] when no block is supplied
          # @raise [Lich::WebUI::Error] for a stopped host or queue overflow
          def queue(&block)
            raise ArgumentError, 'work block is required' unless block
            return if @closed
            if cleanup_thread?
              run_queue_block { synchronize { block.call unless @closed } }
              return :queued
            end
            return if stopping?

            @dispatch.call do
              run_queue_block do
                next if stopping?

                @owner.thread_group.add(Thread.current) unless Script.current.equal?(@owner)
                Script.current # Honor pause after adopting the initially unowned worker.
                synchronize { block.call unless stopping? }
              end
            end
          end

          def register(window)
            @windows << window
          end

          # The submitting viewer is an explicit target for script-thread writes
          # after Save. The core still owns attachment liveness and refuses a
          # closed viewer; this object contains no transport or draft state.
          def viewer_id
            @access_root ? @window_viewers[@access_root] : @callback_viewer
          end

          # One script may own multiple windows with different attachments.
          # Resolve a port read/write against its own window's originating viewer.
          def with_widget(widget)
            synchronize do
              previous = @access_root
              @access_root = root_for(widget)
              yield
            ensure
              @access_root = previous
            end
          end

          def forget(window)
            @window_viewers.delete(window)
            @windows.delete(window)
          end

          def in_callback? = !@callback_viewer.nil?

          def callback(event, terminal: false, widget: nil)
            @owner.thread_group.add(Thread.current) unless Script.current.equal?(@owner)
            synchronize do
              @callback_viewer = event.viewer_id
              @window_viewers[root_for(widget)] = event.viewer_id if widget
              if terminal && widget
                root_for(widget).commit_inputs
              end
              yield
            ensure
              @callback_viewer = nil
            end
          end

          def degrade(operation, reason)
            return if @degradations[operation]

            @degradations[operation] = true
            Lich.log("#{@owner.name}: compatibility #{operation}: #{reason}")
          end

          def refuse(receiver, operation)
            raise UnsupportedOperation, attribution(receiver, operation)
          end

          # Invalid source calls that preserve the existing widget tree remain
          # visible to maintainers, including their script and call location.
          def source_warning(receiver, operation, message)
            Lich.log("#{attribution(receiver, operation)}: #{message}")
          end

          # Isolates script cleanup failures so later handlers/windows still close.
          # Fatal VM failures are not treated as recoverable script errors.
          # @param receiver [Widget] object whose cleanup is running
          # @yield cleanup action
          # @return [Object, nil] cleanup result, or nil after a reported failure
          def cleanup(receiver)
            yield
          rescue StandardError, ScriptError, SystemExit => error
            source_warning(receiver, :destroy, "cleanup failed error=#{error.class} at=#{error.backtrace&.first}")
            nil
          end

          # Attempts every remaining window even if one script callback fails.
          # @return [void]
          def close
            @closed = true
            synchronize { @windows.dup.each { |window| cleanup(window) { window.destroy } } }
          end

          private

          # Recognizes only Script's active cleanup executor for this stopped owner.
          # @return [Boolean] whether queue work may run inline during exit cleanup
          def cleanup_thread?
            @owner.respond_to?(:stopping?) && @owner.stopping? &&
              Script.const_defined?(:CLEANUP_SCRIPT_THREAD_KEY, false) &&
              Thread.current.thread_variable_get(Script::CLEANUP_SCRIPT_THREAD_KEY).equal?(@owner)
          end

          # Applies the legacy error boundary to ordinary and exit-handler work.
          # Only shim class/operation tokens are retained from exception messages;
          # arbitrary script messages may contain sensitive input.
          # @yield queued script operation
          # @return [Object, nil] callback result, or nil after a reported failure
          def run_queue_block
            yield
          rescue StandardError, SyntaxError, SystemExit, SecurityError, SystemStackError, LoadError, NoMemoryError => error
            source = Array(error.backtrace).find { |frame| frame.start_with?("#{@owner.name}:") || frame.include?('.lic:') }
            detail = error.message[/\b(?:class=[\w:]+ )?operation=[\w?!=]+/] if error.is_a?(UnsupportedOperation)
            source_warning(self, :queue, "callback failed error=#{error.class} at=#{source || error.backtrace&.first}#{" rejected=#{detail}" if detail}")
            respond "error in Gtk.queue (#{@owner.name}): #{error.class}; see debug log"
            nil
          end

          # Prevents teardown and retained sessions from admitting fresh UI work.
          # @return [Boolean] whether new or pending callbacks must be discarded
          def stopping?
            @closed || (@owner.respond_to?(:stopping?) && @owner.stopping?)
          end

          def root_for(widget)
            widget = widget.parent while widget.parent
            widget
          end

          def attribution(receiver, operation)
            location = caller_locations.find { |frame| frame.path == @owner.name || frame.path.end_with?('.lic') }
            name = receiver.is_a?(Module) ? receiver.name : receiver.class.name
            "script=#{@owner.name} class=#{name} operation=#{operation} source=#{location || 'unknown'}"
          end
        end
      end
    end
  end
end
