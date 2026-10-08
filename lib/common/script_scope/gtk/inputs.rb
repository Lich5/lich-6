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

        # fletchit/uberfletch persist indices; sbounty removes options by index.
        # Stable internal values distinguish duplicate labels and survive removal.
        # A blank option represents GTK's unselected (-1) state explicitly.
        class ComboBoxText < Widget
          # Creates an unselected list with a permanent blank sentinel option.
          def initialize
            super
            @items = []
            @next_option = 0
            @props.merge!(options: [{ value: 'none', label: '' }], value: 'none')
          end

          # Appends a label under a monotonically assigned option ID, preserving duplicates.
          # @return [ComboBoxText] self
          def append_text(text)
            @next_option += 1
            @items << { value: "option-#{@next_option}", label: String(text) }
            update_options
          end

          # Maps the current stable option ID back to its script-visible index.
          # @return [Integer] zero-based index, or -1 for no selection
          def active = @items.index { |item| item[:value] == read(:value) } || -1
          # Reads the selected label without exposing the internal option ID.
          # @return [String, nil] nil for no selection
          def active_text = active == -1 ? nil : @items.fetch(active)[:label]

          # Selects by script-visible index while keeping wire identity stable.
          # @param index [Integer] zero-based option index, or -1 to clear selection
          # @raise [UnsupportedOperation] for an invalid index
          def active=(index)
            session.refuse(self, :active=) unless index.is_a?(Integer) && index.between?(-1, @items.length - 1)
            write(:value, index == -1 ? 'none' : @items.fetch(index)[:value])
          end
          alias set_active active=

          # Removes one option by index and clears selection if that option was active.
          # @return [ComboBoxText] self
          def remove(index)
            session.refuse(self, :remove) unless index.is_a?(Integer) && index.between?(0, @items.length - 1)
            self.active = -1 if index == active
            @items.delete_at(index)
            update_options
          end

          # Replace sbounty's model inspection with the actual ComboBoxText API.
          # The blank option is permanent and can always represent no choice.
          def remove_all
            self.active = -1
            @items.clear
            update_options
          end

          protected

          def component_type = :select
          def input_property = :value
          def signal_map = { 'changed' => :change }

          private

          def update_options
            write(:options, [{ value: 'none', label: '' }] + @items.map(&:dup))
          end
        end

        # ecure uses the numeric range constructor and synchronous value reads
        # inside value_changed. Browser input remains viewer-local until Save.
        class SpinButton < Entry
          attr_reader :adjustment

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
          # @return [Integer] displayed decimal places
          def digits = read(:digits)

          # Sets bounded display precision without changing the stored numeric value.
          # @return [SpinButton] self
          def digits=(count)
            session.refuse(self, :digits=) unless count.is_a?(Integer) && count.between?(0, 20)
            write(:digits, count)
          end
          alias set_digits digits=

          # Text assignment and editable-mode changes need entry parsing semantics not provided here.
          # @raise [UnsupportedOperation] always
          def text=(_value)
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
          def signal_map = { 'value_changed' => :change }

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
