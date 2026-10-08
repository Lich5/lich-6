# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
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
        class SpinButton < Widget
          # Creates a finite numeric range, initially set to its minimum.
          # @param minimum [Numeric] inclusive lower bound
          # @param maximum [Numeric] inclusive upper bound, greater than minimum
          # @param step [Numeric] positive increment
          # @raise [UnsupportedOperation] for invalid range values
          def initialize(minimum, maximum, step)
            super()
            numbers = [minimum, maximum, step]
            session.refuse(self, :new) unless numbers.all? { |number| number.is_a?(Numeric) && number.finite? }
            session.refuse(self, :new) unless maximum > minimum && step.positive?
            @props.merge!(min: minimum, max: maximum, step: step, value: minimum)
          end

          # Reads viewer-local input during callbacks or committed shadow state afterward.
          # @return [Numeric]
          def value = read(:value)

          # Writes a finite numeric value within the configured inclusive range.
          # @raise [UnsupportedOperation] for out-of-range or nonfinite input
          def value=(number)
            session.refuse(self, :value=) unless number.is_a?(Numeric) && number.finite? && number.between?(@props[:min], @props[:max])
            write(:value, number)
          end

          protected

          def component_type = :number_input
          def input_property = :value
          def signal_map = { 'value_changed' => :change }
        end
      end
    end
  end
end
