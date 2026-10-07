# frozen_string_literal: true

require_relative '../../script_death'
require_relative '../../../webui'
require_relative 'session'
require_relative 'widgets'
require_relative 'layout'
require_relative 'inputs'
require_relative 'dialogs'
require_relative 'style'
require_relative 'displays'
require_relative 'require_boundary'

module Lich
  module Common
    module ScriptScope
      # Availability describes this compatibility surface, never a native load.
      HAVE_GTK = true

      module Gtk
        module WindowType
          TOPLEVEL = :toplevel
        end

        module Version
          MAJOR = 3
          STRING = '3.24.0'.freeze

          def self.const_missing(name)
            Gtk.session.refuse(self, name)
          end
        end

        @sessions = {}.compare_by_identity
        @mutex = Mutex.new

        def self.session
          owner = Script.current
          raise UnsupportedOperation, 'script owner is required for Gtk' unless owner

          current = @mutex.synchronize { @sessions[owner] ||= Session.new(owner) }
          Thread.current.thread_variable_set(:lich_script_compatibility_session, current)
          current
        end

        # Defers one block onto the existing core owner dispatcher. Shadow-state
        # operations inside the block remain synchronous; admission never waits
        # for execution. No native GTK loop or second shim queue is created.
        # @yield script UI work to execute once, in owner enqueue order
        # @return [Symbol, nil] :queued on admission, nil during script teardown
        # @raise [UnsupportedOperation] when no script owner/session is available
        # @raise [ArgumentError] when no block is supplied
        # @raise [Lich::WebUI::Error] when the host stopped or its queue is full
        def self.queue(&block)
          raise ArgumentError, 'work block is required' unless block

          owner = Script.current
          return if owner.respond_to?(:stopping?) && owner.stopping?

          current = owner ? session : Thread.current.thread_variable_get(:lich_script_compatibility_session)
          raise UnsupportedOperation, 'script owner is required for Gtk' unless current

          current.queue(&block)
        end

        # Contract 11.5 dispositions native main-loop calls as lifecycle-only:
        # the core dispatcher already owns the loop and must never be nested.
        def self.main
          session.degrade(:main_loop, 'native main-loop control is replaced by the core dispatcher')
          nil
        end

        def self.main_quit
          session.degrade(:main_loop, 'native main-loop control is replaced by the core dispatcher')
          nil
        end

        def self.const_missing(name)
          session.refuse(self, name)
        end

        def self.method_missing(name, *, **, &)
          session.refuse(self, name)
        end

        def self.respond_to_missing?(*args)
          super
        end

        ScriptDeath.on_death do |owner|
          current = @mutex.synchronize { @sessions.delete(owner) }
          current&.close
        end
      end
    end
  end
end
