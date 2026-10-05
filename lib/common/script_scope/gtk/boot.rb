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

        # Construction is synchronous shadow-state work. The core adapter owns
        # asynchronous rendering; the shim adds no second UI event queue.
        def self.queue(&block)
          # Script.current is cleared before Ruby ensure clauses unwind during
          # termination. Existing widgets still need their idempotent cleanup;
          # a retained session permits that without creating a new UI owner.
          current = Script.current ? session : Thread.current.thread_variable_get(:lich_script_compatibility_session)
          raise UnsupportedOperation, 'script owner is required for Gtk' unless current

          current.synchronize(&block)
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
