# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # fletchit/uberfletch persist indices; sbounty removes options by index.
        # Stable internal values distinguish duplicate labels and survive removal.
        # A blank option represents GTK's unselected (-1) state explicitly.
        class ComboBoxText < Widget
          def initialize
            super
            @items = []
            @next_option = 0
            @props.merge!(options: [{ value: 'none', label: '' }], value: 'none')
          end

          def append_text(text)
            @next_option += 1
            @items << { value: "option-#{@next_option}", label: String(text) }
            update_options
          end

          def active = @items.index { |item| item[:value] == read(:value) } || -1
          def active_text = active == -1 ? nil : @items.fetch(active)[:label]

          def active=(index)
            session.refuse(self, :active=) unless index.is_a?(Integer) && index.between?(-1, @items.length - 1)
            write(:value, index == -1 ? 'none' : @items.fetch(index)[:value])
          end
          alias set_active active=

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
          def initialize(minimum, maximum, step)
            super()
            numbers = [minimum, maximum, step]
            session.refuse(self, :new) unless numbers.all? { |number| number.is_a?(Numeric) && number.finite? }
            session.refuse(self, :new) unless maximum > minimum && step.positive?
            @props.merge!(min: minimum, max: maximum, step: step, value: minimum)
          end

          def value = read(:value)

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
