# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Scalar range state. ScrollAdjustment retains its separate measured-geometry behavior.
        class Adjustment
          attr_reader :session, :lower, :upper, :step_increment, :page_increment, :page_size

          # Creates finite bounds and clamps the initial value into the usable range.
          # @param value [Numeric] initial value
          # @param lower [Numeric] inclusive lower bound
          # @param upper [Numeric] upper extent
          # @param step_increment [Numeric] nonnegative small increment
          # @param page_increment [Numeric] nonnegative large increment
          # @param page_size [Numeric] nonnegative extent reserved for a viewport
          def initialize(value = 0, lower = 0, upper = 0, step_increment = 0, page_increment = 0, page_size = 0)
            @session = Gtk.session
            @signals = Hash.new { |hash, key| hash[key] = [] }
            valid = [value, lower, upper, step_increment, page_increment, page_size].all? { |number| finite_number?(number) }
            valid &&= lower <= upper && [step_increment, page_increment, page_size].all? { |number| number >= 0 }
            session.refuse(self, :new) unless valid
            @lower, @upper, @step_increment, @page_increment, @page_size = lower, upper, step_increment, page_increment, page_size
            @value = value.clamp(lower, [lower, upper - page_size].max)
          end

          # Reads the bound input's viewer state during a callback, or retained scalar state.
          # @return [Numeric]
          def value = @widget ? @widget.value : @value

          # Clamps a programmatic value and signals only an actual change.
          # @return [Adjustment] self
          def set_value(number)
            session.refuse(self, :value=) unless finite_number?(number)
            target = number.clamp(lower, [lower, upper - page_size].max)
            session.synchronize do
              changed = value != target
              @widget&.send(:apply_adjustment_value, target)
              @value = target
              notify_value_changed if changed
            end
            self
          end
          alias value= set_value

          # Connects ordered scalar value or parameter-change handlers.
          # @return [Integer] connection count for this signal
          def signal_connect(name, &block)
            name = name.to_s.tr('-', '_')
            session.refuse(self, "signal:#{name}") unless %w[changed value_changed].include?(name) && block
            @signals[name] << block
            @signals[name].length
          end

          # Binds one numeric input; sharing a mutable adjustment across controls is not yet supported.
          # @api private
          # @return [void]
          def bind(widget)
            session.refuse(self, :bind) unless widget.session.equal?(session) && (!@widget || @widget.equal?(widget))
            @widget = widget
          end

          # Dispatches an observed input change after its viewer value has been validated.
          # @api private
          # @return [void]
          def notify_value_changed
            @signals['value_changed'].dup.each { |handler| handler.call(self) }
          end

          private

          def finite_number?(number)
            number.is_a?(Numeric) && number.real? && number.finite?
          end
        end
      end
    end
  end
end
