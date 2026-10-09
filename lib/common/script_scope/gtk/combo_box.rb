# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # The entry child uses its combo's single shared input, never a second browser control.
        class ComboEntry < Entry
          # Creates a bounded model-backed combo or its single-input entry facade.
          # @param combo [ComboBox] owning editable combo
          def initialize(combo)
            super()
            @combo, @parent = combo, combo
          end

          def text = @combo.entry_text

          # Assigns literal free text through the owning combo's value contract.
          # @param value [String] literal free text, including blank
          # @return [ComboBox] owning combo
          def text=(value)
            @combo.set_entry_text(value)
          end
          alias set_text text=

          # Forwards changed notifications from the combo's single shared input.
          # @param name [String, Symbol] changed
          # @yieldparam entry [ComboEntry] this entry
          # @return [Integer] handler count
          def signal_connect(name, &handler)
            session.refuse(self, :signal_connect) unless name.to_s == 'changed'
            super
          end

          # @raise [UnsupportedOperation] this facade cannot be packed independently
          def materialize
            session.refuse(self, :materialize)
          end

          protected

          def write(property, _value)
            session.refuse(self, property)
          end
        end

        # A flat model-backed select. Wire IDs name rows, so duplicate labels remain distinct.
        # The permanent blank sentinel represents active=-1 for both new and attached viewers.
        class ComboBox < Widget
          attr_reader :model, :child, :entry_text_column

          # Creates a bounded model-backed combo or its single-input entry facade.
          # @param source [ListStore, Boolean, nil] model, or legacy text-only constructor flag
          # @param entry [Boolean] expose an editable entry child
          # @param has_entry [Boolean] equivalent legacy keyword
          def initialize(source = nil, entry: false, has_entry: false)
            super()
            valid = source.nil? || source == true || source == false || (source.instance_of?(ListStore) && source.session.equal?(session))
            valid &&= [true, false].include?(entry) && [true, false].include?(has_entry)
            session.refuse(self, :new) unless valid
            @entry_text_column, @label_column = 0, 0
            @props.merge!(options: [{ value: 'none', label: '' }], value: 'none', empty_value: 'none', editable: entry || has_entry)
            @props[:free_text_prefix] = 'text:' if @props[:editable]
            @child = ComboEntry.new(self) if @props[:editable]
            self.model = source.instance_of?(ListStore) ? source : ListStore.new(String)
          end

          def has_entry? = !child.nil?

          # Rebinds the options and clears a selection whose row belongs to the old model.
          # @param model [ListStore] same-owner flat store
          # @return [ListStore]
          def model=(model)
            session.refuse(self, :model=) unless model.instance_of?(ListStore) && model.session.equal?(session)
            validate_label_column(model, @label_column) if @handle
            session.synchronize do
              @model&.unwatch(self)
              @model = model
              model.watch(self) unless destroyed?
              model_changed!
            end
          end
          alias set_model model=

          # Maps labels to a validated String column without changing option identities.
          # @param column [Integer] String model column shown in the entry and options
          # @return [Integer]
          def entry_text_column=(column)
            validate_label_column(model, column)
            @entry_text_column = @label_column = column
            model_changed!
          end
          alias set_entry_text_column entry_text_column=

          # Accepts one text renderer; composite option cells remain unsupported.
          # @param renderer [CellRendererText] same-owner plain text renderer
          # @param expand [Boolean] single-renderer allocation flag
          # @return [ComboBox] self
          def pack_start(renderer, expand)
            valid = renderer.instance_of?(CellRendererText) && renderer.session.equal?(session) && [true, false].include?(expand)
            session.refuse(self, :pack_start) unless valid && !@renderer
            @renderer = renderer
            self
          end

          # Accepts the single text binding for the packed plain renderer.
          # @param renderer [CellRendererText] the packed renderer
          # @param name [String, Symbol] text
          # @param column [Integer] model label column
          # @return [Integer]
          def add_attribute(renderer, name, column)
            session.refuse(self, :add_attribute) unless renderer.equal?(@renderer) && name.to_s == 'text'
            self.entry_text_column = column
          end

          # Applies one text mapping through the same label-column validation.
          # @param renderer [CellRendererText] packed renderer
          # @param attributes [Hash] one text mapping
          # @return [Integer]
          def set_attributes(renderer, attributes)
            session.refuse(self, :set_attributes) unless attributes.keys.map(&:to_s) == ['text']
            add_attribute(renderer, :text, attributes.values.first)
          end

          def active_iter = model.find_key(read(:value))
          def active = model.rows.index(active_iter) || -1
          def active_text = has_entry? ? entry_text : active_iter&.[](@label_column)

          # Selects by current model position or explicitly clears with -1.
          # @param index [Integer] model-order index, or -1 to clear
          # @return [ComboBox] self
          def active=(index)
            session.refuse(self, :active=) unless index.is_a?(Integer) && index.between?(-1, model.size - 1)
            set_choice(index == -1 ? 'none' : model.rows[index].key)
          end
          alias set_active active=

          # Selects an actual same-model row or explicitly clears with nil.
          # @param iter [TreeIter, nil] actual live model row, or nil to clear
          # @return [ComboBox] self
          def active_iter=(iter)
            session.refuse(self, :active_iter=) unless iter.nil? || model.iter_is_valid?(iter)
            set_choice(iter ? iter.key : 'none')
          end
          alias set_active_iter active_iter=

          # Appends a label to a single-String-column model.
          # @param text [String] text for a single-string-column model
          # @return [ComboBox] self
          def append_text(text)
            text_model!
            session.synchronize { model.append[0] = String(text) }
            self
          end

          # Prepends a label without changing existing row identities.
          # @param text [String] label to prepend
          # @return [ComboBox] self
          def prepend_text(text)
            text_model!
            session.synchronize { model.prepend[0] = String(text) }
            self
          end

          # Inserts a label at a model position without using its label as identity.
          # @param index [Integer] insertion position
          # @param text [String] new label
          # @return [ComboBox] self
          def insert_text(index, text)
            text_model!
            session.synchronize { model.insert(index)[0] = String(text) }
            self
          end

          # Removes one model row; viewer reconciliation clears only that retired choice.
          # @param index [Integer] row index to remove
          # @return [ComboBox] self
          def remove(index)
            session.refuse(self, :remove) unless index.is_a?(Integer) && index.between?(0, model.size - 1)
            model.remove(model.rows[index])
            self
          end

          def remove_all
            model.clear
            self
          end

          # Decodes literal entry text or resolves the currently selected label.
          # @return [String] selected label or literal viewer text
          # @api private
          def entry_text
            value = read(:value)
            return '' if value == 'none'
            model.find_key(value)&.[](@label_column) || value.delete_prefix('text:')
          end

          # Encodes literal text separately from option IDs and the clearing sentinel.
          # @param text [String] literal text for the entry facade
          # @return [ComboBox] self
          # @api private
          def set_entry_text(text)
            session.refuse(self, :text=) unless has_entry? && text.is_a?(String) && text.length <= Lich::WebUI::Contract::BOUNDS[:input_text] - 5
            set_choice("text:#{text}")
          end

          # Updates labels and identity choices while preserving surviving viewer selections.
          # @return [void]
          # @api private
          def model_changed!
            return if destroyed?
            # Custom models can be installed before pack_start/add_attribute chooses
            # their String column. Materialization still refuses an incomplete mapping.
            return unless model.column_types[@label_column] == String
            options = [{ value: 'none', label: '' }] + model.rows.map { |iter| { value: iter.key, label: iter[@label_column] } }
            session.refuse(self, :options) if options.length > Lich::WebUI::Contract::BOUNDS[:collection]
            old_keys = @props[:options].map { |option| option[:value] }
            new_keys = options.map { |option| option[:value] }
            %i[value].each do |property|
              value = @props[property]
              @props[property] = 'none' if old_keys.include?(value) && !new_keys.include?(value)
              committed = @committed[property]
              @committed[property] = 'none' if old_keys.include?(committed) && !new_keys.include?(committed)
            end
            write(:options, options)
          end

          # Rejects oversized labels/options before any shared model observer is updated.
          # @return [void]
          # @api private
          def model_will_change!
            return unless @handle || model.column_types[@label_column] == String
            options = [{ value: 'none', label: '' }] + model.rows.map { |iter| { value: iter.key, label: iter[@label_column] } }
            Lich::WebUI::Validator.new.validate_component!(:select, @props.merge(options: options, value: 'none'), owner: 'shim', page_id: nil, cid: nil)
          end

          # Releases the model observer even when destruction comes from an ancestor.
          # @return [void]
          def mark_destroyed
            model.unwatch(self)
            child&.mark_destroyed
            super
          end

          protected

          def component_type = :select
          def input_property = :value
          def signal_map = { 'changed' => :change }

          # Refuses unfinished label mappings before allocating a visible control.
          # @return [Hash] complete shared select properties
          # @api private
          def component_props
            validate_label_column(model, @label_column)
            super
          end

          def emit_handlers(event, signal: nil)
            super
            child&.send(:emit_handlers, event, signal: signal)
          end

          private

          # Validates the live write before notifying combo and entry observers.
          # @param value [String] row ID, clearing sentinel or encoded literal text
          # @return [ComboBox] self
          # @api private
          def set_choice(value)
            previous = read(:value)
            write(:value, value)
            emit_handlers(:change) unless previous == value
            self
          end

          # Prevents text convenience methods from inventing values for extra model columns.
          # @return [void]
          # @api private
          def text_model!
            session.refuse(self, :text_model) unless model.column_types == [String]
          end

          # Requires an actual String column instead of silently stringifying arbitrary data.
          # @param candidate [ListStore] candidate model
          # @param column [Integer] label column
          # @return [void]
          # @api private
          def validate_label_column(candidate, column)
            session.refuse(self, :text_column) unless candidate.get_column_type(column) == String
          end
        end
      end
    end
  end
end
