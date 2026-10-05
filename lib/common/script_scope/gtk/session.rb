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

          def initialize(owner)
            @owner = owner
            @port = Lich::WebUI.adapter(owner: owner, viewer: self)
            @mutex = Monitor.new
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

          def close
            synchronize { @windows.dup.each(&:destroy) }
          end

          private

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
