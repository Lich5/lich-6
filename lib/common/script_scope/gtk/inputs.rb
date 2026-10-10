# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # A legacy tooltip manager owns only literal text associations in its Script session.
        class Tooltips
          # Creates an enabled manager without native GTK resources.
          def initialize
            @session = Gtk.session
            @tips = {}.compare_by_identity
            @enabled = true
          end

          # Associates literal public text with a same-owner widget.
          # @param widget [Widget] target widget
          # @param text [String, nil] public tooltip, or nil to clear it
          # @param private_text [String, nil] must be absent or empty; private help is unsupported
          # @return [Tooltips] self
          def set_tip(widget, text, private_text = nil)
            valid = widget.is_a?(Widget) && widget.session.equal?(@session)
            valid &&= text.nil? || text.is_a?(String)
            valid &&= private_text.nil? || private_text == ''
            @session.refuse(self, :set_tip) unless valid
            widget.set_tooltip_text(@enabled ? text.to_s : '')
            @tips[widget] = text.to_s
            self
          end

          # Restores the registered public text after disabling this manager.
          # @return [Tooltips] self
          def enable
            @tips.each { |widget, text| widget.set_tooltip_text(text) unless widget.destroyed? }
            @enabled = true
            self
          end

          # Hides registered tooltips while retaining their text for re-enabling.
          # @return [Tooltips] self
          def disable
            @tips.each_key { |widget| widget.set_tooltip_text('') unless widget.destroyed? }
            @enabled = false
            self
          end
        end

        # Search fields retain ordinary Entry changed/activate signals and shared input state.
        # Delayed search-changed notifications remain unsupported.
        class SearchEntry < Entry
          protected

          # Uses the existing typed search presentation without installing another event loop.
          # @return [Hash] shared text-input properties
          def component_props
            @editable ? super.merge(search: true) : super
          end
        end

        # Text convenience form backed by the same real model as legacy ComboBox.
        # Existing index, duplicate-label and blank-selection behavior is preserved.
        class ComboBoxText < ComboBox
          # @param entry [Boolean] expose the combo's editable entry facade
          # @param has_entry [Boolean] legacy spelling of entry
          def initialize(entry: false, has_entry: false)
            super(nil, entry: entry, has_entry: has_entry)
          end
        end

        # ecure uses the numeric range constructor and synchronous value reads
        # inside value_changed. Browser input remains viewer-local until Save.
        class SpinButton < Entry
          attr_reader :adjustment

          # Read-only view of the validated numeric value. It deliberately owns
          # no draft buffer: edits still go through the shared numeric control.
          class Buffer
            def initialize(spin)
              @spin = spin
            end

            # @return [String] viewer-local formatted number during callbacks
            def text = @spin.text

            # Buffer mutation and native entry-buffer operations are unsupported.
            def method_missing(name, *, **, &)
              @spin.session.refuse(self, name)
            end

            def respond_to_missing?(*args) = super
          end

          # @return [Buffer] stable read-only numeric text facade
          def buffer = @buffer ||= Buffer.new(self)

          # Accepts (min, max, step) or (Adjustment, climb_rate = 0, digits = 0).
          # Scalar adjustments require a positive step, nonempty range, and zero page size.
          # @raise [UnsupportedOperation] for unsupported parameter values or shared adjustments
          def initialize(*args)
            super()
            if args.first.instance_of?(Adjustment)
              session.refuse(self, :new) unless args.length.between?(1, 3)
              @adjustment = args[0]
              climb, precision = args.fetch(1, 0), args.fetch(2, 0)
            else
              session.refuse(self, :new) unless args.length == 3
              minimum, maximum, step = args
              session.refuse(self, :new) unless args.all? { |number| number.is_a?(Numeric) && number.real? && number.finite? }
              @strict_range = true
              @adjustment = Adjustment.new(minimum, minimum, maximum, step, step * 10, 0)
              climb = 0
              mantissa, exponent = step.to_f.to_s.split('e')
              fraction = mantissa.split('.').last.sub(/0+\z/, '').length
              precision = [[fraction - exponent.to_i, 0].max, 20].min
            end
            valid = @adjustment.session.equal?(session) && @adjustment.upper > @adjustment.lower
            valid &&= @adjustment.step_increment.positive? && @adjustment.page_size.zero?
            valid &&= climb.is_a?(Numeric) && climb.real? && climb.finite? && climb >= 0
            valid &&= precision.is_a?(Integer) && precision.between?(0, 20)
            session.refuse(self, :new) unless valid
            @props.merge!(min: @adjustment.lower, max: @adjustment.upper, step: @adjustment.step_increment,
                          value: @adjustment.value, digits: precision, acceleration: climb,
                          page_step: @adjustment.page_increment, snap_to_step: false, stepper_buttons: true)
            @adjustment.bind(self)
            @adjustment.signal_connect('value_changed') { emit_handlers(:change) }
          end

          # Reads viewer-local input during callbacks or committed shadow state afterward.
          # @return [Numeric]
          def value = read(:value)

          # Writes through the adjustment, clamping finite input to its configured range.
          # The earlier (min, max, step) constructor retains its strict range refusal.
          # @return [SpinButton] self
          def set_value(number)
            if @strict_range
              valid = number.is_a?(Numeric) && number.real? && number.finite? && number.between?(@props[:min], @props[:max])
              session.refuse(self, :value=) unless valid
            end
            @adjustment.value = number
            self
          end
          alias value= set_value

          # @return [Integer] current value rounded to the nearest integer
          def value_as_int = value.round
          # @return [String] current value formatted to the requested decimal precision
          def text = format("%.#{digits}f", value)

          # Numeric browser changes arrive parsed and range-validated before callbacks.
          # There is no separate GTK entry buffer to flush; re-publish the current
          # viewer value without recursively emitting value-changed.
          # @return [SpinButton] self
          def update
            write(:value, value)
          end

          # @return [Integer] displayed decimal places
          def digits = read(:digits)

          # Sets bounded display precision without changing the stored numeric value.
          # @return [SpinButton] self
          def digits=(count)
            session.refuse(self, :digits=) unless count.is_a?(Integer) && count.between?(0, 20)
            write(:digits, count)
          end
          alias set_digits digits=

          # A pre-render numeric text declaration initializes the existing
          # adjustment. There is no independent draft string; invalid/nonfinite
          # text and published text assignments remain unsupported.
          # @raise [UnsupportedOperation] for invalid or live text assignments
          def text=(text)
            number = Float(text) if text.is_a?(String)
            session.refuse(self, :text=) unless !@handle && number&.finite?
            set_value(number)
          rescue ArgumentError, TypeError
            session.refuse(self, :text=)
          end
          alias set_text text=
          def editable=(_value)
            session.refuse(self, :editable=)
          end

          # The shared number input accepts numeric values only.
          # @raise [UnsupportedOperation] when nonnumeric editing is requested
          def set_numeric(enabled)
            session.refuse(self, :numeric=) unless enabled == true
            self
          end
          alias numeric= set_numeric

          protected

          def component_type = :number_input
          def component_props = @props.dup
          def input_property = :value
          # The supported numeric editor has one validated change stream, with
          # no independent GTK text draft. Both legacy signal names observe that
          # stream; registering either name does not create a second wire event.
          def signal_map = { 'value_changed' => :change, 'changed' => :change }

          def apply_adjustment_value(number)
            write(:value, number)
          end

          def bind_event(event)
            return super unless event == :change

            session.port.bind(@handle, event, proc do |context|
              session.callback(context, widget: self) do
                @adjustment.notify_value_changed
              end
            end)
          end
        end
      end
    end
  end
end
