# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      # Script-local scheduling only; never loads native GLib or replaces Ruby Timeout.
      module GLib
        # Keeps unimplemented calls and constants on the attributed refusal path.
        module Boundary
          # @raise [Gtk::UnsupportedOperation] for unimplemented GLib operations
          def method_missing(name, *, **, &) = Gtk.session.refuse(self, name)
          # @raise [Gtk::UnsupportedOperation] for unimplemented GLib constants
          def const_missing(name) = Gtk.session.refuse(self, name)
        end
        extend Boundary

        module Timeout
          extend Boundary

          # @param interval [Integer] milliseconds, including deferred zero
          # @return [Integer] owner-bound source ID; truthy callback results repeat
          def self.add(interval, &block)
            Gtk.session.schedule(self, :add, interval, &block)
          end

          # @param interval [Integer] seconds converted to bounded milliseconds
          # @return [Integer] owner-bound source ID
          def self.add_seconds(interval, &block)
            Gtk.session.refuse(self, :add_seconds) unless interval.is_a?(Integer)
            Gtk.session.schedule(self, :add_seconds, interval * 1000, &block)
          end
        end

        module Idle
          extend Boundary

          # Defers onto the owner queue with the core's 1ms fairness floor.
          # @return [Integer] cancellable source ID, never an inline callback result
          def self.add(&block)
            Gtk.session.schedule(self, :add, 0, &block)
          end
        end

        module Source
          extend Boundary

          # @param id [Integer] ID returned by this owner's scheduling call
          # @return [Boolean] false when already removed or finished
          def self.remove(id)
            Gtk.session.remove_source(self, id)
          end
        end
      end
    end
  end
end
