# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Use the contracted split primitive: the first child's natural width
        # establishes the initial divider, and the viewer owns later dragging.
        class Paned < Box
          # Creates the supported horizontal split using the common layout contract.
          # @raise [UnsupportedOperation] for other orientations
          def initialize(orientation)
            super(orientation)
            session.refuse(self, :new) unless orientation == :horizontal
          end

          # Adds the first split child only while the split is empty.
          # @return [Paned] self
          def add1(child)
            session.refuse(self, :add1) unless children.empty?
            add(child)
          end

          # Adds the second split child only after the first exists.
          # @return [Paned] self
          def add2(child)
            session.refuse(self, :add2) unless children.length == 1
            add(child)
          end

          protected

          def component_type = :split
          def component_props = super.except(:cols, :gap).merge(orientation: :horizontal)
          def builtin_events = [:move]
        end

        class Overlay < Widget
          alias add_overlay add

          protected

          def component_type = :overlay
        end

        class ProgressBar < Widget
          # Initializes a progress control at an empty fraction.
          def initialize
            super
            @props[:value] = 0.0
          end

          # Bounds the displayed fraction without changing the script's arithmetic.
          # NaN has no representable WebUI fraction; retain the last display value
          # and report that degradation once rather than aborting the whole update.
          # @param value [Numeric] requested fraction; infinities saturate at an end
          # @return [ProgressBar] this progress bar
          # @raise [UnsupportedOperation] when the value is not a real number
          def set_fraction(value)
            session.refuse(self, :set_fraction) unless value.is_a?(Numeric) && value.real?
            fraction = value.to_f
            if fraction.nan?
              session.degrade(:progress_fraction_nan, 'undefined fraction; retaining the last displayed value')
              return self
            end

            write(:value, fraction.clamp(0.0, 1.0))
          end

          # Returns the cached bounded progress-style facade for this widget.
          # @return [StyleContext]
          def style_context = @style_context ||= StyleContext.new(self)

          protected

          def component_type = :progress
        end
      end
    end
  end
end
