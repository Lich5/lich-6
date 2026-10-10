# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module SelectionMode
          NONE = :none
          SINGLE = :single
          BROWSE = :browse
          MULTIPLE = :multiple
        end

        module SortType
          ASCENDING = :ascending
          DESCENDING = :descending
        end

        # Literal scalar cell presentation. Editing proposes a value; only script callbacks
        # may commit it to the model. Rich attributes and arbitrary data functions are refused.
        class CellRendererText < ModelObject
          attr_reader :editable

          def initialize
            super
            @editable, @handlers, @columns = false, [], []
          end

          # Enables edit proposals and updates already attached column definitions.
          # @param value [Boolean] whether the browser may propose an edit
          # @return [Boolean] accepted flag
          def editable=(value)
            session.refuse(self, :editable=) unless value == true || value == false
            @editable = value
            @columns.each(&:changed!)
          end
          alias set_editable editable=
          def editable? = editable

          # Registers only the signal supported by this compatibility object.
          # @param name [String, Symbol] only edited (or toggled for toggle renderers)
          # @yieldparam renderer [CellRendererText] emitting object
          # @yieldparam path [String] current model path
          # @yieldparam text [String] proposed text; omitted for toggled
          # @return [Integer] connection count
          def signal_connect(name, &handler)
            session.refuse(self, :signal_connect) unless name.to_s == signal_name && handler
            @handlers << handler
            @handlers.length
          end

          # Routes a named property through the same bounded setters as direct calls.
          # @param name [String, Symbol] supported property name
          # @param value [Object] property value
          # @return [Object] setter result
          def set_property(name, value)
            setter = "#{name.to_s.tr('-', '_')}="
            session.refuse(self, name) unless respond_to?(setter)
            public_send(setter, value)
          end

          # Retains a same-owner dependent column for subsequent configuration updates.
          # @param column [TreeViewColumn] owning presentation column
          # @return [void]
          # @api private
          def watch(column)
            session.refuse(self, :watch) unless column.session.equal?(session)
            @columns << column unless @columns.include?(column)
          end

          def unwatch(column) = @columns.delete(column)
          def editor = editable ? { type: 'text' } : nil
          def value_attribute = 'text'
          def signal_name = 'edited'

          # Dispatches the renderer signal without changing the model first.
          # @param path [String] current model path, resolved from the stable event row
          # @param value [Object] proposed scalar
          # @return [void]
          # @api private
          def emit_edit(path, value)
            @handlers.dup.each { |handler| handler.call(self, path, value.to_s) }
          end
        end

        # A boolean cell whose toggled signal carries a path and never pre-mutates its row.
        class CellRendererToggle < CellRendererText
          def initialize
            super
            @editable = true
          end

          alias activatable= editable=
          alias set_activatable editable=
          def activatable? = editable
          def value_attribute = 'active'
          def signal_name = 'toggled'
          def editor = { type: 'checkbox', disabled: !editable }

          # Dispatches the renderer signal without changing the model first.
          # @param path [String] current model path
          # @param _value [Boolean] proposal; the script owns the actual toggle
          # @return [void]
          # @api private
          def emit_edit(path, _value)
            @handlers.dup.each { |handler| handler.call(self, path) }
          end
        end

        # A closed text-choice editor backed by a same-owner flat store.
        class CellRendererCombo < CellRendererText
          attr_reader :model, :text_column

          def initialize
            super
            @model, @text_column = nil, 0
          end

          # Rebinds the same-owner model and detaches the previous observer.
          # @param model [ListStore] flat same-owner choice model
          # @return [ListStore]
          def model=(model)
            session.refuse(self, :model=) unless model.instance_of?(ListStore) && model.session.equal?(session)
            @model&.unwatch(self)
            @model = model
            model.watch(self) unless @columns.empty?
            model_changed!
          end
          alias set_model model=

          # Chooses the String column supplying choice labels.
          # @param column [Integer] string column used as the edited text
          # @return [Integer]
          def text_column=(column)
            session.refuse(self, :text_column=) unless column.is_a?(Integer) && column >= 0
            @text_column = column
            model_changed!
          end
          alias set_text_column text_column=

          # Freeform cell-combo entries need a separate editor contract.
          # @param value [Boolean] only false is supported
          # @return [Boolean]
          def has_entry=(value)
            session.refuse(self, :has_entry=) unless value == false
          end

          # Retains a same-owner dependent column for subsequent configuration updates.
          def watch(column)
            super
            @model&.watch(self)
          end

          def unwatch(column)
            super
            @model&.unwatch(self) if @columns.empty?
          end

          def model_changed! = @columns.each(&:changed!)

          # Validates choice changes before the backing model publishes to any observer.
          # @return [void]
          # @api private
          def model_will_change!
            @columns.each { |column| column.view&.model_will_change! }
          end

          # Serializes labels as text values, deduplicating identical text choices only.
          # @return [Hash, nil] shared closed-choice editor
          # @api private
          def editor
            return nil unless editable
            session.refuse(self, :model) unless model && model.get_column_type(text_column) == String
            values = model.rows.map { |iter| iter[text_column] }.uniq
            session.refuse(self, :options) if values.length > Lich::WebUI::Contract::BOUNDS[:collection]
            { type: 'select', options: values.map { |text| { value: text, label: text } } }
          end
        end

        # One literal renderer per visible column. Column identities survive model mutations.
        class TreeViewColumn < ModelObject
          attr_reader :renderer, :value_column, :view, :key, :title, :sort_column_id

          # @param title [String] header caption
          # @param renderer [CellRendererText, nil] text/toggle/choice renderer
          # @param attributes [Hash] text or active mapped to a model column
          def initialize(title = '', renderer = nil, attributes = {})
            super()
            @title, @visible, @resizable, @width = String(title), true, false, nil
            @value_column, @sort_column_id = 0, nil
            @key = "c#{SecureRandom.hex(8)}"
            pack_start(renderer, true) if renderer
            set_attributes(renderer, attributes) unless attributes.empty?
          end

          # Attaches the single supported cell renderer to this column.
          # @param renderer [CellRendererText] one same-owner renderer
          # @param expand [Boolean] supported single-renderer allocation flag
          # @return [TreeViewColumn] self
          def pack_start(renderer, expand)
            view&.check_column_structure!
            valid = renderer.is_a?(CellRendererText) && renderer.session.equal?(session) && [true, false].include?(expand)
            session.refuse(self, :pack_start) unless valid && !@renderer
            @renderer = renderer
            renderer.watch(self)
            self
          end

          # Maps one literal value attribute to its model column.
          # @param renderer [CellRendererText] this column's renderer
          # @param attributes [Hash] one text/active binding
          # @return [TreeViewColumn] self
          def set_attributes(renderer, attributes)
            view&.check_column_structure!
            normalized = attributes.transform_keys(&:to_s)
            valid = renderer.equal?(@renderer) && normalized.keys == [renderer.value_attribute]
            column = normalized[renderer.value_attribute]
            session.refuse(self, :set_attributes) unless valid && column.is_a?(Integer) && column >= 0
            @value_column = column
            changed!
            self
          end

          def add_attribute(renderer, name, column) = set_attributes(renderer, name => column)
          def visible? = @visible

          # Controls column visibility before the view is materialized.
          # @param value [Boolean] visibility; structural changes must precede materialization
          # @return [Boolean]
          def visible=(value)
            session.refuse(self, :visible=) unless [true, false].include?(value)
            view&.check_column_structure!
            @visible = value
          end

          # Updates the header caption without changing the column identity.
          # @param value [String] header caption
          # @return [String]
          def title=(value)
            @title = String(value)
            changed!
          end
          alias set_title title=

          # Enables the shared browser column-width interaction.
          # @param value [Boolean] enable browser column resizing
          # @return [Boolean]
          def resizable=(value)
            session.refuse(self, :resizable=) unless [true, false].include?(value)
            @resizable = value
            changed!
          end
          alias set_resizable resizable=

          # Applies a bounded positive initial column width.
          # @param value [Integer] positive column width
          # @return [Integer]
          def fixed_width=(value)
            session.refuse(self, :fixed_width=) unless value.is_a?(Integer) && value.between?(1, 65_536)
            @width = value
            changed!
          end
          alias set_fixed_width fixed_width=

          # Fixed GTK column measurement uses browser allocation and any explicit width.
          # @param value [Symbol] only :fixed is accepted
          # @return [void]
          def sizing=(value)
            session.refuse(self, :sizing=) unless value == :fixed
            session.degrade(:column_sizing, 'fixed column measurement uses browser layout and explicit column widths')
          end

          # Maps the header gesture to built-in sorting on a model column.
          # @param column [Integer] model column used by built-in scalar sorting
          # @return [Integer]
          def sort_column_id=(column)
            session.refuse(self, :sort_column_id=) unless column.is_a?(Integer) && column >= 0
            @sort_column_id = column
            changed!
          end
          alias set_sort_column_id sort_column_id=

          # Assigns one owning view; columns cannot be shared between views.
          # @param owner [TreeView] single owning view
          # @return [void]
          # @api private
          def attach(owner)
            session.refuse(self, :attach) unless !view && owner.session.equal?(session)
            @view = owner
          end

          def release = renderer&.unwatch(self)
          def changed! = view&.columns_changed!

          # Projects the supported renderer properties into the shared table schema.
          # @return [Hash] shared column schema
          # @api private
          def definition
            session.refuse(self, :renderer) unless renderer
            result = { key: key, label: title, resizable: @resizable, sortable: !sort_column_id.nil? }
            result[:width] = @width if @width
            result[:editor] = renderer.editor if renderer.editor
            result
          end
        end

        # Viewer-local selection facade; script callbacks observe the originating viewer.
        class TreeSelection < ModelObject
          attr_reader :mode

          # @param view [TreeView] owning table
          def initialize(view)
            super(session: view.session)
            @session, @view, @mode, @handlers = view.session, view, :single, []
          end

          # Selects the supported selection policy and reconciles existing choices.
          # @param mode [Symbol] :none, :single, :browse or :multiple
          # @return [Symbol]
          def mode=(mode)
            session.refuse(self, :mode=) unless %i[none single browse multiple].include?(mode)
            @view.selection_mode_changed(mode)
            @mode = mode
          end
          alias set_mode mode=

          # Reads the originating viewer's single selection; multiple mode requires iteration.
          # @return [TreeIter, nil] selected row; multiple mode requires selected_rows/selected_each
          def selected
            session.refuse(self, :selected) if mode == :multiple
            @view.selected_iters.first
          end

          # Returns paths before the model, matching the GTK3 Ruby binding's out-parameter order.
          # @return [Array(Array<TreePath>, ListStore)] selected paths and their model
          def selected_rows = [@view.selected_iters.map(&:path), @view.model]
          def count_selected_rows = @view.selected_iters.length
          def iter_is_selected?(iter) = @view.selected_iters.include?(iter)
          def path_is_selected?(path) = iter_is_selected?(@view.model&.get_iter(path))

          # Yields independent row handles in current model order.
          # @yieldparam model [ListStore] current model
          # @yieldparam path [TreePath] current path
          # @yieldparam iter [TreeIter] independent selected row
          # @return [Enumerator, Array<TreeIter>]
          def selected_each
            return enum_for(:selected_each) unless block_given?
            @view.selected_iters.each { |iter| yield @view.model, iter.path, iter }
          end

          # Selects a live model row, adding to the set only in multiple mode.
          # @param iter [TreeIter] live row in this view's model
          # @return [TreeSelection] self
          def select_iter(iter)
            session.refuse(self, :select_iter) unless @view.model&.iter_is_valid?(iter)
            keys = mode == :multiple ? @view.selected_iters.map(&:key) | [iter.key] : [iter.key]
            @view.select_keys(keys)
            self
          end

          def select_path(path) = select_iter(@view.model&.get_iter(path))

          # Removes a selected row while respecting browse mode's required selection.
          # @param iter [TreeIter] live row to deselect
          # @return [TreeSelection] self
          def unselect_iter(iter)
            session.refuse(self, :unselect_iter) unless @view.model&.iter_is_valid?(iter)
            @view.select_keys(@view.selected_iters.map(&:key) - [iter.key])
            self
          end

          def unselect_path(path) = unselect_iter(@view.model&.get_iter(path))
          def unselect_all = @view.select_keys([])

          # Selects every current model row in multiple mode.
          # @return [TreeView] selects all rows only in multiple mode
          def select_all
            session.refuse(self, :select_all) unless mode == :multiple
            @view.select_keys(@view.model ? @view.model.rows.map(&:key) : [])
          end

          # Registers only the signal supported by this compatibility object.
          # @param name [String, Symbol] changed
          # @yieldparam selection [TreeSelection] this facade
          # @return [Integer] connection count
          def signal_connect(name, &handler)
            session.refuse(self, :signal_connect) unless name.to_s == 'changed' && handler
            @handlers << handler
            @handlers.length
          end

          def changed! = @handlers.dup.each { |handler| handler.call(self) }
        end

        # A typed table projection of a script-owned model, with independent viewer state.
        class TreeView < Widget
          attr_reader :model, :selection

          # @param model [ListStore, TreeStore, nil] same-session model
          def initialize(model = nil)
            super()
            @columns = []
            @selection = TreeSelection.new(self)
            @props.merge!(selection: 'single', selected: [], expanded: [], cursor: {}, headers: true, sort_mode: 'model')
            self.model = model if model
          end

          def columns = @columns.dup
          alias get_selection selection

          # Rebinds this view while leaving the previous model and other views intact.
          # @param model [ListStore, TreeStore, nil] replacement or nil to clear
          # @return [ListStore, TreeStore, nil]
          def model=(model)
            valid = model.nil? || (model.is_a?(ListStore) && model.session.equal?(session))
            session.refuse(self, :model=) unless valid
            session.synchronize do
              validate_columns(model)
              @model&.unwatch(self)
              @model = model
              model&.watch(self) unless destroyed?
              model_changed!
            end
          end
          alias set_model model=

          # Attaches a column during construction, before a live schema exists.
          # @param column [TreeViewColumn] same-owner column, before materialization
          # @return [Integer] number of columns
          def append_column(column)
            check_column_structure!
            session.refuse(self, :append_column) unless column.is_a?(TreeViewColumn) && column.session.equal?(session)
            column.attach(self)
            @columns << column
            @columns.length
          end

          # Controls header visibility independently of captions and model columns.
          # @param value [Boolean] explicit header visibility
          # @return [TreeView] self
          def headers_visible=(value)
            session.refuse(self, :headers_visible=) unless [true, false].include?(value)
            write(:headers, value)
          end
          alias set_headers_visible headers_visible=
          def headers_visible? = read(:headers)

          # Selects a displayed String model column for viewer-local incremental search.
          # @param column [Integer] model column, or -1 to disable
          # @return [Integer] accepted model index
          def search_column=(column)
            session.refuse(self, :search_column=) unless column.is_a?(Integer) && column >= -1
            check_column_structure!
            @search_column = column
          end

          # GTK's fixed-row measurement optimization is omitted; browser layout measures rows.
          # @param value [Boolean] requested measurement optimization
          # @return [void]
          def fixed_height_mode=(value)
            session.refuse(self, :fixed_height_mode=) unless [true, false].include?(value)
            session.degrade(:fixed_height_mode, 'GTK row measurement optimization omitted; browser measures row heights') if value
          end

          # Maps a bounded grid-line policy to the shared table presentation.
          # @param value [Symbol] :none, :horizontal, :vertical or :both
          # @return [TreeView] self
          def enable_grid_lines=(value)
            session.refuse(self, :enable_grid_lines=) unless %i[none horizontal vertical both].include?(value)
            write(:grid_lines, value)
          end
          alias set_enable_grid_lines enable_grid_lines=

          # Resolves the current viewer cursor back to a model path and column.
          # @return [Array(TreePath, TreeViewColumn), Array(nil, nil)] viewer cursor
          def cursor
            state = view_state(:cursor)
            iter = model&.find_key(state[:row])
            [iter&.path, @columns.find { |column| column.key == state[:column] }]
          end

          # Selects and focuses a row/cell. Starting an editor programmatically is unsupported.
          # @param path [TreePath, String, Array<Integer>] model path
          # @param column [TreeViewColumn, nil] optional visible column
          # @param start_editing [Boolean] must be false
          # @return [TreeView] self
          def set_cursor(path, column = nil, start_editing = false)
            iter = model&.get_iter(path)
            valid = iter && start_editing == false && (column.nil? || visible_columns.include?(column))
            session.refuse(self, :set_cursor) unless valid
            state = { row: iter.key }
            state[:column] = column.key if column
            write(:cursor, state)
            select_keys([iter.key]) unless selection.mode == :none
            self
          end

          def expand_all = write(:expanded, parent_keys)
          def collapse_all = write(:expanded, [])
          def row_expanded?(path) = view_state(:expanded).include?(model&.get_iter(path)&.key)

          # Expands a parent and optionally all of its descendant parents.
          # @param path [TreePath, String, Array<Integer>] parent row
          # @param open_all [Boolean] also expand all descendant parents
          # @return [Boolean] false for a leaf/missing row
          def expand_row(path, open_all = false)
            session.refuse(self, :expand_row) unless [true, false].include?(open_all)
            iter = model&.get_iter(path)
            return false unless iter && parent_keys.include?(iter.key)
            keys = [iter.key]
            if open_all
              prefix = iter.path.indices
              keys |= model.rows.select { |row| row.path.indices.first(prefix.length) == prefix }.map(&:key) & parent_keys
            end
            write(:expanded, view_state(:expanded) | keys)
            true
          end

          # Collapses a parent while retaining descendant expansion choices.
          # @param path [TreePath, String, Array<Integer>] row to collapse
          # @return [Boolean] whether an expanded row was collapsed
          def collapse_row(path)
            iter = model&.get_iter(path)
            return false unless iter && row_expanded?(path)
            write(:expanded, view_state(:expanded) - [iter.key])
            true
          end

          # Detaches nonvisual observers during both direct and ancestor destruction.
          # @return [void]
          def mark_destroyed
            model&.unwatch(self)
            @columns.each(&:release)
            super
          end

          # Retains selection, expansion and cursor before terminal callbacks/closure.
          # @return [void]
          def commit_inputs
            if @handle && !destroyed?
              %i[selected expanded cursor].each do |property|
                @committed[property] = session.with_widget(self) { session.port.get(@handle, property) }
              end
            end
            super
          end

          # Resolves surviving selected identities in current model order.
          # @return [Array<TreeIter>] current viewer's surviving selected rows
          # @api private
          def selected_iters
            keys = (view_state(:selected) || []).to_h { |key| [key, true] }
            model ? model.rows.select { |iter| keys[iter.key] } : []
          end

          # Updates the target viewer's selection and emits changed only when it changes.
          # @param keys [Array<String>] same-model identities
          # @return [TreeView] self
          # @api private
          def select_keys(keys)
            session.refuse(self, :selection) if selection.mode == :none && !keys.empty?
            return self if selection.mode == :browse && keys.empty? && model && !model.empty?
            previous = view_state(:selected)
            write(:selected, keys)
            selection.changed! unless previous == keys
            self
          end

          # Reconciles selection before publishing a different selection policy.
          # @param mode [Symbol] validated GTK selection mode
          # @return [void]
          # @api private
          def selection_mode_changed(mode)
            keys = view_state(:selected)
            keys = [] if mode == :none
            keys = keys.first(1) unless mode == :multiple
            keys = model.rows.first(1).map(&:key) if mode == :browse && keys.empty? && model
            write(:selected, [])
            write(:selection, mode == :multiple ? 'multi' : mode.to_s)
            write(:selected, keys)
          end

          # Reprojects only shared data; live viewer state is reconciled by row identity in core.
          # @return [void]
          # @api private
          def model_changed!
            return if destroyed?
            rows = if @handle
                     @validated_rows && @validated_model.equal?(model) && @validated_revision == model&.revision ? @validated_rows : row_definitions
                   end
            # Before materialization only retained identities need reconciliation;
            # no renderer reads cell values just to populate an unseen model.
            survives = ->(key) { model&.find_key(key) }
            %i[selected expanded].each do |property|
              @props[property] = @props[property].select(&survives)
              @committed[property] = @committed[property].select(&survives) if @committed.key?(property)
            end
            @props[:cursor] = {} unless survives.call(@props[:cursor][:row])
            if @committed[:cursor] && !survives.call(@committed[:cursor][:row])
              @committed[:cursor] = {}
            end
            if @props[:selection] == 'browse' && @props[:selected].empty?
              @props[:selected] = [model&.iter_first&.key].compact
            end
            write(:rows, rows) if @handle
          ensure
            @validated_rows = @validated_model = @validated_revision = nil
          end

          # Checks a candidate model snapshot without changing this view or its live adapter.
          # @return [void]
          # @api private
          def model_will_change!
            props = @handle ? component_props : unmaterialized_model_props
            keys = props[:rows].map { |row| row[:key] }
            props[:selected] = props[:selected] & keys
            props[:expanded] = props[:expanded] & keys
            props[:cursor] = {} unless keys.include?(props[:cursor][:row])
            Lich::WebUI::Validator.new.validate_component!(:table, props, owner: 'shim', page_id: nil, cid: nil)
            if @handle
              @validated_rows, @validated_model, @validated_revision = props[:rows], model, model&.revision
            end
          end

          # Validates renderer configuration before updating live column definitions.
          # @return [void]
          # @api private
          def columns_changed!
            @validated_rows = @validated_model = @validated_revision = nil
            validate_columns(model)
            if @handle
              write(:columns, column_definitions)
              write(:sortable, visible_columns.any?(&:sort_column_id))
            end
          end

          # Structural column edits are bounded to construction; no partial live schema is published.
          # @return [void]
          # @api private
          def check_column_structure!
            session.refuse(self, :column_structure) if @handle
          end

          protected

          def component_type = :table
          def signal_map = { 'row_activated' => :row_activate, 'row_expanded' => :row_toggle, 'row_collapsed' => :row_toggle, 'cursor_changed' => :cursor_change }
          def builtin_events = %i[selection_change cell_edit sort_change] + (@drag_destination ? [:row_drop] : [])

          def component_props
            validate_columns(model)
            @props.merge(columns: column_definitions, rows: row_definitions, sortable: visible_columns.any?(&:sort_column_id)).merge(search_props)
          end

          # Search is deliberately bounded to a visible plain-text column.
          def search_props
            return {} if @search_column.nil? || @search_column == -1
            # Numeric text renderers already project their display text; prefix
            # search uses that same representation, without changing model types.
            column = visible_columns.find { |item| item.value_column == @search_column }
            session.refuse(self, :search_column) unless column && [String, Integer, Float].include?(model&.get_column_type(@search_column))
            { search_column: column.key }
          end

          # Events resolve current paths from stable IDs; removed rows cannot target their replacements.
          # @param event [Symbol] validated shared event
          # @return [String] binding ID
          # @api private
          def bind_event(event)
            return super if event == :pointer_press
            session.port.bind(@handle, event, proc do |context|
              session.callback(context, terminal: %i[row_activate row_drop].include?(event), widget: self) do
                payload = context.payload
                iter = model&.find_key(payload[:row])
                case event
                when :row_drop then dispatch_row_drop(context)
                when :selection_change then selection.changed!
                when :cell_edit
                  column = visible_columns.find { |candidate| candidate.key == payload[:column] }
                  begin
                    column.renderer.emit_edit(iter.path.to_s, payload[:value]) if iter && column
                  ensure
                    # Repaint authoritative data after a no-op or failing handler too.
                    model_changed!
                  end
                when :sort_change
                  column = visible_columns.find { |candidate| candidate.key == payload[:column] }
                  model.set_sort_column_id(column.sort_column_id, payload[:direction] == 'asc' ? :ascending : :descending) if model && column
                when :row_activate
                  column = visible_columns.find { |candidate| candidate.key == payload[:column] }
                  emit_row(event, 'row_activated', iter.path, column) if iter
                when :row_toggle
                  emit_row(event, payload[:expanded] ? 'row_expanded' : 'row_collapsed', iter, iter.path) if iter
                when :cursor_change then emit_row(event, 'cursor_changed') if iter
                end
              end
            end)
          end

          private

          # Model insertion/setters already enforce row count, depth, identities and
          # scalar types. An unseen view needs only column/editor validation and the
          # rows referenced by retained state. Empty cell maps avoid reading every
          # cell; omitted parents rely on the model's checked tree invariant.
          # Full projection validation still runs when the view is materialized.
          # @return [Hash] candidate schema and retained row identities
          # @api private
          def unmaterialized_model_props
            validate_columns(model)
            keys = (@props[:selected] + @props[:expanded] + [@props[:cursor][:row]]).compact.uniq
            rows = keys.filter_map { |key| { key: key, cells: {} } if model&.find_key(key) }
            @props.merge(columns: column_definitions, rows: rows, sortable: visible_columns.any?(&:sort_column_id))
          end

          def visible_columns = @columns.select(&:visible?)
          def column_definitions = visible_columns.empty? ? [{ key: 'empty', label: '' }] : visible_columns.map(&:definition)
          def parent_keys = model ? model.rows.select { |iter| model.iter_has_child?(iter) }.map(&:key) : []

          # Uses live viewer state only inside callbacks, and retained/default state afterward.
          # @param property [Symbol] selected, expanded or cursor
          # @return [Array, Hash] scoped table state
          # @api private
          def view_state(property)
            if @handle && !destroyed? && session.in_callback?
              session.with_widget(self) { session.port.get(@handle, property) } || @props[property]
            else
              @committed.fetch(property, @props[property])
            end
          end

          # Checks model-column mappings before exposing a table projection.
          # @param candidate [ListStore, nil] candidate backing model
          # @return [void]
          # @api private
          def validate_columns(candidate)
            return unless candidate
            visible_columns.each do |column|
              type = candidate.get_column_type(column.value_column)
              session.refuse(self, :cell_type) if column.renderer.is_a?(CellRendererToggle) && type != TrueClass
              candidate.get_column_type(column.sort_column_id) if column.sort_column_id
            end
          end

          # Serializes scalar cells and stable parent identities, never Ruby model objects.
          # @return [Array<Hash>] shared rows in model order
          # @api private
          def row_definitions
            return [] unless model
            model.rows.map do |iter|
              row = { key: iter.key, cells: visible_columns.to_h { |column| [column.key, iter[column.value_column]] } }
              parent = model.iter_parent(iter)
              row[:parent] = parent.key if parent
              row
            end
          end

          # Keeps expanded/collapsed handlers distinct although they share one wire event.
          # @param event [Symbol] contracted event
          # @param signal [String] normalized GTK signal
          # @param args [Array<Object>] resolved GTK arguments
          # @return [void]
          # @api private
          def emit_row(event, signal, *args)
            @signals.fetch(event, []).dup.each { |name, handler| handler.call(self, *args) if name == signal }
          end
        end
      end
    end
  end
end
