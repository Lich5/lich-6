# frozen_string_literal: true

require 'cgi'

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Shadow objects preserve synchronous reads and GTK mutator chaining.
        # Only materialized widgets own opaque port handles. Destruction removes
        # the browser surface while leaving Ruby metadata readable, as MyFletch
        # reads and normalizes its entries after destroying the setup window.
        class Widget
          attr_reader :session, :parent
          attr_writer :placement

          # Creates script-owned shadow state without allocating a browser control.
          def initialize
            @session = Gtk.session
            @props = {}
            @children = []
            @signals = {}
            @committed = {}
            @handle = nil
            @destroyed = false
          end

          # Refuses unsupported widget operations with source attribution.
          # @raise [UnsupportedOperation] always
          def method_missing(name, *, **, &)
            session.refuse(self, name)
          end

          # GTK returns a collection snapshot. A source may remove each child
          # while iterating that snapshot without skipping alternating entries.
          def children = @children.dup

          # Detaches a child from this widget while retaining its shadow state and handle.
          # @return [Widget] self
          # @raise [UnsupportedOperation] unless this widget is its parent
          def remove(child)
            session.refuse(self, :remove) unless child.parent.equal?(self)
            session.port.detach(@handle, child.materialize) if @handle
            @children.delete(child)
            child.parent = nil
            self
          end

          # Does not advertise unsupported native widget methods through reflection.
          # @return [Boolean]
          def respond_to_missing?(*args)
            super
          end

          # Appends a same-session child through the shared single-parent/cycle checks.
          # @return [Widget] self
          def add(child)
            insert_child(child, @children.length)
          end

          # spellson keeps its display ordered as spells appear and expire.
          def reorder_child(child, index)
            session.refuse(self, :reorder_child) unless child.parent.equal?(self) && index.is_a?(Integer) && index.between?(0, @children.length - 1)
            session.synchronize do
              @children.delete(child)
              @children.insert(index, child)
              if @handle
                session.port.detach(@handle, child.materialize)
                session.port.attach(@handle, child.materialize, index)
              end
            end
            self
          end

          def insert_child(child, index)
            session.refuse(self, :add) unless child.is_a?(Widget)
            session.refuse(self, :add) unless child.session.equal?(session)
            ancestor = self
            while ancestor
              session.refuse(self, :add) if ancestor.equal?(child)
              ancestor = ancestor.parent
            end
            # A widget has one parent and one rendered identity. betazzherb
            # packs the same row twice; retain it once and report the source
            # defect rather than duplicating inputs in the submission scope.
            if child.parent.equal?(self)
              session.source_warning(self, :add, 'child already packed; duplicate ignored')
              return self
            end
            session.refuse(self, :add) if child.parent
            session.port.attach(@handle, child.materialize, index) if @handle
            child.parent = self
            @children.insert(index, child)
            self
          end
          private :insert_child

          # Maps accepted legacy signals to core events; destroy handlers accumulate separately.
          # @return [Integer] compatibility connection count
          # @raise [UnsupportedOperation] for an unmapped signal
          def signal_connect(name, &block)
            if name.to_s == 'destroy'
              (@destroy_handlers ||= []) << block
              return @destroy_handlers.length
            end
            event = signal_map[name.to_s] || session.refuse(self, "signal:#{name}")
            @signals[event] = block
            bind_event(event) if @handle
            @signals.length
          end

          # Maps content border spacing to the shared control's margin.
          # @return [Widget] self
          def set_border_width(value)
            write(:margin, Integer(value))
          end
          alias border_width= set_border_width

          # Sets the requested content width through the shared property contract.
          # @return [Widget] self
          def set_width_request(value)
            write(:width, Integer(value))
          end
          alias width_request= set_width_request

          # Sets the requested content height through the shared property contract.
          # @return [Widget] self
          def set_height_request(value)
            write(:height, Integer(value))
          end
          alias height_request= set_height_request

          # Applies requested dimensions, leaving an axis unchanged when its request is -1.
          # @return [Widget] self
          def set_size_request(width, height)
            set_width_request(width) unless width == -1
            set_height_request(height) unless height == -1
            self
          end

          # Supplies literal tooltip text rather than browser markup.
          # @return [Widget] self
          def set_tooltip_text(value)
            write(:tooltip, String(value))
          end
          alias tooltip_text= set_tooltip_text

          # Accepts the measured normal-state token while retaining browser-theme backgrounds.
          # @return [Widget] self
          # @raise [UnsupportedOperation] for other state/color objects
          def override_background_color(state, colour)
            session.refuse(self, :override_background_color) unless state == :normal && colour.is_a?(Gdk::RGBA)
            session.degrade(:background_colour, 'widget background colours follow browser theme; displayed values are retained')
            self
          end

          # Validates an expansion request and reports browser-owned space distribution.
          # @return [Widget] self
          def set_hexpand(value)
            session.refuse(self, :set_hexpand) unless [true, false].include?(value)
            session.degrade(:expansion, 'available space is distributed by browser layout')
            self
          end
          alias set_vexpand set_hexpand

          # Updates the left entry of the widget's explicit per-side margin.
          # @return [Widget] self
          def set_margin_left(value)
            write(:margin, (@props[:margin].is_a?(Hash) ? @props[:margin] : {}).merge(left: value))
          end

          # Updates the right entry of the widget's explicit per-side margin.
          # @return [Widget] self
          def set_margin_right(value)
            write(:margin, (@props[:margin].is_a?(Hash) ? @props[:margin] : {}).merge(right: value))
          end

          # Maps the supported start/center/end alignment tokens to the shared control.
          # @raise [UnsupportedOperation] for other tokens
          def halign=(value)
            session.refuse(self, :halign=) unless %i[start center end].include?(value)
            write(:align, value)
          end

          # Decodes text entities but refuses tags instead of forwarding markup to the browser.
          # @raise [UnsupportedOperation] when tags are present
          def tooltip_markup=(value)
            session.refuse(self, :tooltip_markup=) if value.match?(/<[^>]*>/)
            write(:tooltip, CGI.unescapeHTML(value))
          end

          # Clears tooltip text when disabled; enabling does not invent tooltip content.
          # @raise [UnsupportedOperation] for nonboolean values
          def has_tooltip=(enabled)
            session.refuse(self, :has_tooltip=) unless enabled == true || enabled == false
            write(:tooltip, '') unless enabled
          end

          # Sensitivity controls interaction through the existing disabled
          # attribute; input values remain available when a field is disabled.
          def set_sensitive(value)
            session.refuse(self, :set_sensitive) unless [true, false].include?(value)
            @sensitive = value
            if session.port.schema(component_type)[:properties].key?(:disabled)
              write(:disabled, !value)
            else
              session.degrade(:noninteractive_sensitivity, 'noninteractive text uses browser theme; sensitivity remains readable')
              self
            end
          end
          alias sensitive= set_sensitive

          # Reads retained interaction sensitivity, including for noninteractive controls.
          # @return [Boolean] true by default
          def sensitive? = @sensitive != false

          # Creates descendants before the root can publish, then binds supported events once.
          # @return [Lich::WebUI::Adapter::Handle] cached opaque control handle
          def materialize
            return @handle if @handle

            # Build descendants before the page starts scheduling delivery. A
            # long script constructor must not publish a half-built window.
            child_handles = @children.map(&:materialize)
            @handle = session.port.create(component_type, component_props.merge(placement: @placement || {}))
            child_handles.each { |child| session.port.attach(@handle, child) }
            (builtin_events + signal_map.values + @signals.keys).uniq.each { |event| bind_event(event) }
            @handle
          end

          # Reports shadow lifecycle state without querying a retired adapter handle.
          # @return [Boolean]
          def destroyed? = @destroyed
          # Reports explicitly shown shadow state for a widget not yet destroyed.
          # @return [Boolean]
          def visible? = !@destroyed && @props[:hidden] == false

          # Walks shadow parents to the owning root.
          # @return [Widget] top-level ancestor or self
          def toplevel
            parent ? parent.toplevel : self
          end

          # Retains a child modal so parent destruction can cancel it.
          # @return [void]
          def own_dialog(dialog)
            (@dialogs ||= []) << dialog
          end

          # Releases a completed/destroyed modal from parent cleanup.
          # @return [void]
          def forget_dialog(dialog)
            @dialogs&.delete(dialog)
          end

          # Clears the shared hidden property.
          # @return [Widget] self
          def show
            write(:hidden, false)
          end

          # Shows this widget and every shadow descendant.
          # @return [Widget] self
          def show_all
            show
            @children.each(&:show_all)
            self
          end

          # Removes the widget once and runs each destroy handler independently.
          # @return [Widget] self, including repeated destruction
          def destroy
            return self if @destroyed

            @dialogs&.dup&.each { |dialog| session.cleanup(dialog) { dialog.destroy } }
            session.port.destroy(@handle) if @handle
            @parent&.send(:forget_child, self)
            @parent = nil
            mark_destroyed
            session.forget(self)
            @destroy_handlers&.each { |handler| session.cleanup(self) { handler.call(self) } }
            self
          end

          # Marks the shadow subtree retired while preserving script-readable metadata.
          # @return [void]
          def mark_destroyed
            @destroyed = true
            @children.each(&:mark_destroyed)
          end

          # Drafts stay in the core viewer store. Only a terminal action copies
          # current input into script-owned shadow state for synchronous reads
          # after the dialog closes; disconnect never leaves draft copies here.
          def commit_inputs
            property = input_property
            if property && @handle && !@destroyed
              @committed[property] = session.with_widget(self) { session.port.get(@handle, property) }
            end
            @children.each(&:commit_inputs)
          end

          protected

          attr_writer :parent

          def forget_child(child)
            @children.delete(child)
          end

          def component_props = @props.dup
          def signal_map = {}
          def input_property = nil
          def builtin_events = []

          # Reads current viewer input only inside a live callback; otherwise uses committed/default shadow state.
          # @return [Object] synchronous script-visible value
          def read(property)
            session.synchronize do
              if property == input_property && @handle && !@destroyed && session.in_callback?
                session.with_widget(self) { session.port.get(@handle, property) }
              else
                @committed.fetch(property, @props[property])
              end
            end
          end

          # Validates a live adapter write before updating script-visible shadow state.
          # After destruction, retained metadata can still be updated without touching the retired handle.
          # @return [Widget] self
          def write(property, value)
            session.synchronize do
              # A rejected port write must leave synchronous script reads at
              # their last valid value, including after window destruction.
              session.with_widget(self) { session.port.set(@handle, port_property(property), value) } if @handle && !@destroyed
              if property == input_property && @committed.key?(property)
                @committed[property] = value
              else
                @props[property] = value
              end
            end
            self
          end

          def port_property(property) = property

          # Commits terminal input before invoking legacy save/close handlers.
          # @param event [Symbol] shared-control event mapped to a GTK signal
          # @return [String] adapter binding identifier
          # @api private
          def bind_event(event)
            widget = self
            session.port.bind(@handle, event, proc do |context|
              session.callback(context, terminal: !context.viewer_id.nil? && %i[activate submit close].include?(event), widget: widget) do
                result = @signals[event]&.call(widget)
                widget.destroy if event == :close && result != true
              end
            end)
          end
        end

        class Window < Widget
          TOPLEVEL = :toplevel
          Allocation = Data.define(:width, :height)

          # Creates a compact window inheriting the application's GTK preference.
          # @param kind [Symbol, String] :toplevel or the window title
          def initialize(kind = :toplevel)
            super()
            session.refuse(self, :new) unless kind == :toplevel || kind.is_a?(String)
            @props[:title] = kind.is_a?(String) ? kind : ''
            @props.merge!(bare: true, density: :compact)
            session.register(self)
          end

          # Updates the requested page/window title through the adapter.
          # @return [Window] self
          def title=(value)
            write(:title, String(value))
          end
          alias set_title title=

          # Reads the current shadow window title.
          # @return [String]
          def title = read(:title)

          # Requests integer window dimensions through the shared page size property.
          # @return [Window] self
          def resize(width, height)
            write(:size, [Integer(width), Integer(height)])
          end
          alias set_default_size resize

          # sloot restores its saved dimensions with independent setters.
          def default_width=(value)
            resize(value, (@props[:size] || [0, 0])[1])
          end

          # Updates the requested height while preserving the current requested width.
          # @return [Window] self
          def default_height=(value)
            resize((@props[:size] || [0, 0])[0], value)
          end

          # Materializes the window while reporting that raising/focus is host-controlled.
          # @return [Window] self
          def present
            show_all
            session.degrade(:present, 'raising an existing window is controlled by the browser host')
            self
          end

          # Accepts the legacy center hint without promising host placement control.
          # @return [Window] self
          # @raise [UnsupportedOperation] for other position tokens
          def set_window_position(value)
            session.refuse(self, :set_window_position) unless value == :center
            session.degrade(:window_position, 'initial placement is controlled by the browser host')
            self
          end

          # Requests integer desktop coordinates through the page position property.
          # @return [Window] self
          def move(x, y)
            write(:position, [Integer(x), Integer(y)])
          end

          # Reads live geometry, or the final observed position after destruction.
          # @return [Array<Integer>] x/y coordinates, defaulting to zero before observation
          def position
            return (@observed_geometry&.fetch(:position) || [0, 0]).dup if destroyed?

            (@handle ? session.port.get(@handle, :position) : read(:position)) || [0, 0]
          end

          # Reads live or retained content dimensions without reviving a destroyed handle.
          # @return [Allocation] width/height pair
          def allocation
            size = if destroyed?
                     @observed_geometry&.values_at(:width, :height)
                   else
                     @handle ? session.port.get(@handle, :size) : read(:size)
                   end
            size ||= @observed_geometry&.values_at(:width, :height) || @props[:size] || [0, 0]
            Allocation.new(*size)
          end

          # Keep geometry available to original destroy/exit handlers after
          # the adapter has retired the window handle.
          def destroy
            unless destroyed?
              dimensions = allocation
              @observed_geometry = { width: dimensions.width, height: dimensions.height, position: position }
            end
            super
          end

          # Validates the legacy flag and reports that window resizing is host-controlled.
          # @raise [UnsupportedOperation] for nonboolean values
          def resizable=(value)
            session.refuse(self, :resizable=) unless value == true || value == false
            session.degrade(:resizable, 'window resizing is controlled by the browser host')
          end

          # Reports the host-owned window-icon limitation without loading native image objects.
          # @return [Window] self
          def set_icon(_icon)
            session.degrade(:window_icon, 'browser window icons are host-controlled')
            self
          end
          alias icon= set_icon

          # Requests native topmost behavior through the shared presentation contract.
          # Unsupported hosts retain the request and report their normal degradation.
          # @param value [Boolean] whether to keep this window above ordinary windows
          # @return [void]
          def keep_above=(value)
            session.refuse(self, :keep_above=) unless value == true || value == false
            write(:presentation, (@props[:presentation] || {}).merge(always_on_top: value))
          end

          # Window borders belong to its content, not the page schema.
          def set_border_width(value)
            @content_margin = Integer(value)
            self
          end
          alias border_width= set_border_width

          # Applies content margins and materializes this page for the shared publication path.
          # @return [Window] self
          def show_all
            @children.each { |child| child.set_border_width(@content_margin) } if @content_margin
            materialize
            self
          end

          protected

          def component_type = :page
          def signal_map = { 'delete_event' => :close }
          def builtin_events = %i[close configure]

          # Preserve the latest validated browser measurements for the original
          # script's allocation/position reads, including its exit cleanup.
          def bind_event(event)
            return super unless event == :configure

            session.port.bind(@handle, :configure, proc do |context|
              session.callback(context, widget: self) { @observed_geometry = context.payload.dup }
            end)
          end
        end

        class Box < Widget
          # Creates a horizontal grid or vertical stack with the requested spacing.
          # Numeric orientation 0/1 is accepted for the measured GTK enum usage.
          def initialize(orientation = :horizontal, spacing = 0)
            super()
            # sloot uses GTK's numeric vertical enum in its Save button box.
            orientation = { 0 => :horizontal, 1 => :vertical }.fetch(orientation, orientation)
            session.refuse(self, :new) unless %i[horizontal vertical].include?(orientation)
            @orientation = orientation
            @end_children = []
            @props[:gap] = Integer(spacing)
          end

          # Inserts before end-packed children while retaining accepted positional packing arguments.
          # @return [Box] self
          def pack_start(child, *packing, expand: true, fill: true, padding: 0)
            pack(child, packing, expand: expand, fill: fill, padding: padding, ending: false)
          end

          # GTK packs each new end child before the previous end children.
          # hands_and_room depends on this to show right, left, then room.
          def pack_end(child, *packing, expand: true, fill: true, padding: 0)
            pack(child, packing, expand: expand, fill: fill, padding: padding, ending: true)
          end

          protected

          def pack(child, packing, expand:, fill:, padding:, ending:)
            session.refuse(self, :pack_start) if packing.length > 3
            expand = packing[0] if packing.length >= 1
            fill = packing[1] if packing.length >= 2
            padding = packing[2] if packing.length >= 3
            child.set_border_width(padding) if padding.positive?
            # Horizontal grouping and fixed requested widths carry the measured
            # packing intent; browser layout owns excess-space distribution.
            session.degrade(:packing, 'excess space follows browser layout') if expand != fill
            session.synchronize do
              @end_children.select! { |widget| widget.parent.equal?(self) }
              previous_cols = [@children.length, 1].max
              growing = @handle && @orientation == :horizontal && !@children.include?(child)
              session.port.set(@handle, :cols, @children.length + 1) if growing
              begin
                insert_child(child, @children.length - @end_children.length)
              rescue StandardError
                session.port.set(@handle, :cols, previous_cols) if growing
                raise
              end
              @end_children << child if ending && !@end_children.include?(child)
            end
            self
          end

          def component_type = @orientation == :vertical ? :stack : :grid

          def component_props
            @orientation == :vertical ? super : super.merge(cols: [@children.length, 1].max)
          end
        end

        class Alignment < Widget
          # Maps a bounded horizontal fraction to start/center/end in a stack wrapper.
          # All four legacy arguments are validated; arbitrary GTK allocation is not reproduced.
          def initialize(xalign, yalign, xscale, yscale)
            super()
            session.refuse(self, :new) unless [xalign, yalign, xscale, yscale].all? { |value| value.is_a?(Numeric) && value.between?(0, 1) }
            @props[:align] = xalign == 1 ? :end : (xalign.zero? ? :start : :center)
          end

          # Maps each padding edge to its corresponding shared margin.
          # @return [Alignment] self
          def set_padding(top, bottom, left, right)
            write(:margin, { top: top, bottom: bottom, left: left, right: right })
          end

          protected

          def component_type = :stack
        end

        class Frame < Widget
          # GTK creates no label widget when the constructor label is absent.
          # @param label [String, nil] frame label; an empty string creates a blank label
          def initialize(label = nil)
            super()
            @props[:label] = label unless label.nil?
          end

          # Copies the supplied label's text into the shared group label.
          # @return [Frame] self
          def set_label_widget(label)
            write(:label, label.text)
          end

          protected

          def component_type = :group
        end

        class Notebook < Widget
          # Creates an empty tab set with the first tab selected by default.
          def initialize
            super
            @props[:names] = []
            @props[:selected] = 0
          end

          # Validates the border request and reports theme-controlled tab borders.
          # @return [Notebook] self
          def set_show_border(value)
            session.refuse(self, :set_show_border) unless value == true || value == false
            session.degrade(:notebook_border, 'tab border styling follows the browser theme')
            self
          end
          alias show_border= set_show_border

          # Appends a child and its label in source order.
          # @return [Integer] zero-based index of the appended page
          def append_page(child, label)
            @props[:names] << label.text
            add(child)
            @children.length - 1
          end

          protected

          def component_type = :tabs

          # Tab selection is a core viewer-state event even when the source
          # registers no switch-page callback. It must have a server binding.
          def builtin_events = [:select]
        end

        class Label < Widget
          # Creates centered, nonwrapping literal text with GTK-compatible empty defaults.
          def initialize(text = '')
            super()
            @props.merge!(content: text.to_s, align: :center, wrap: false)
          end

          # Reads the retained literal label content.
          # @return [String]
          def text = read(:content)

          # Writes literal label content through the shared text control.
          # @return [Label] self
          def text=(value)
            write(:content, String(value))
          end
          alias set_text text=

          # Maps horizontal 0/intermediate/1 to start/center/end after validating both axes.
          # @return [Label] self
          def set_alignment(horizontal, vertical)
            session.refuse(self, :set_alignment) unless [horizontal, vertical].all? { |value| value.is_a?(Numeric) && value.between?(0, 1) }
            write(:align, horizontal.zero? ? :start : (horizontal == 1 ? :end : :center))
          end

          # Validates selectability and reports that browser text remains selectable.
          # @return [Label] self
          def set_selectable(value)
            session.refuse(self, :set_selectable) unless [true, false].include?(value)
            session.degrade(:text_selection, 'browser text remains selectable') unless value
            self
          end

          # Translates the measured markup subset into literal text and bounded emphasis/color.
          # Unknown tags are refused; source markup is never forwarded as browser HTML.
          # @return [Label] self
          # @raise [UnsupportedOperation] for unsupported tags
          def set_markup(value)
            # Boon's measured blue bold tip maps to literal text and the native
            # bounded color record. Source markup never reaches the browser.
            if (tip = value.match(/\A<span color="blue" weight="bold">([^<>]*)<\/span>\z/m))
              write(:foreground, Color.parse('blue'))
              write(:emphasis, :strong)
              return write(:content, CGI.unescapeHTML(tip[1]))
            end
            # Other measured headings use only b/big wrappers. Unknown markup
            # fails at its source call rather than reaching the browser.
            tags = value.scan(/<[^>]*>/)
            # armor's charts use literal spans with colour and font metadata.
            # Preserve every character; never pass markup or CSS to the client.
            span = /\A<span(?: (?:color=(?:'[^'<>]*'|"[^"<>]*")|font_desc=(?:'[^'<>]*'|"[^"<>]*")))+>\z/
            session.refuse(self, :set_markup) if tags.any? { |tag| !%w[<b> <big> </b> </big> </span>].include?(tag) && !span.match?(tag) }
            session.degrade(:markup_style, 'chart colours and font faces follow browser theme; chart text is retained') if tags.any? { |tag| tag.start_with?('<span') }
            write(:emphasis, value.include?('<b>') ? :strong : :normal)
            write(:content, CGI.unescapeHTML(value.gsub(/<[^>]*>/, '')))
          end

          # Sets the shared text wrapping property.
          # @return [Label] self
          def set_wrap(value) = write(:wrap, value)
          alias wrap= set_wrap

          # Uses the larger requested axis as uniform text margin.
          # @return [Label] self
          def set_padding(x, y)
            write(:margin, [Integer(x), Integer(y)].max)
          end

          # Converts the bounded character-width hint using a nominal eight-pixel glyph width.
          # Reports that actual typography follows the browser font.
          # @return [Label] self
          def set_width_chars(count)
            session.refuse(self, :set_width_chars) unless count.is_a?(Integer) && count.between?(1, 512)
            session.degrade(:character_width, 'character width is an initial hint using the browser font')
            write(:width, count * 8)
          end

          protected

          def component_type = :text
        end

        class Entry < Widget
          # Creates an empty editable entry; read-only mode must be selected before materialization.
          def initialize
            super
            @props[:value] = ''
            @editable = true
          end

          # Reads current callback input or retained committed/default entry text.
          # @return [String]
          def text = read(:value)

          # Updates the input value or read-only text projection through the same shadow path.
          # @return [Entry] self
          def text=(value)
            write(:value, String(value))
          end
          alias set_text text=

          # Sets literal placeholder text for the shared input control.
          # @return [Entry] self
          def placeholder_text=(value)
            write(:placeholder, String(value))
          end

          # Maps a unit-interval fraction to start/center/end text alignment.
          # @raise [UnsupportedOperation] for out-of-range values
          def xalign=(value)
            session.refuse(self, :xalign=) unless value.is_a?(Numeric) && value.between?(0, 1)
            write(:align, value.zero? ? :start : (value == 1 ? :end : :center))
          end

          # Chooses input versus literal text before any handle is allocated.
          # @raise [UnsupportedOperation] after materialization
          def editable=(value)
            session.refuse(self, :editable=) if @handle
            @editable = !!value
          end

          # Maps only the accepted font-weight token to text emphasis.
          # @return [Entry] self
          def override_font(font)
            session.refuse(self, :override_font) unless font.is_a?(Pango::FontDescription)
            write(:emphasis, font.weight == :bold ? :strong : :normal)
          end

          protected

          def component_type = @editable ? :text_input : :text
          def input_property = @editable ? :value : nil
          def signal_map = @editable ? { 'changed' => :change, 'activate' => :submit, 'focus-in-event' => :focus } : {}
          def port_property(property) = !@editable && property == :value ? :content : property

          def component_props
            @editable ? super.merge(change_mode: :input) : super.except(:value).merge(content: @props[:value])
          end
        end

        class CheckButton < Widget
          # Creates an unchecked checkbox with the supplied literal label.
          def initialize(label = '')
            super()
            @props.merge!(label: label, checked: false)
          end

          # Reads current callback selection or retained checkbox state.
          # @return [Boolean]
          def active? = read(:checked)

          # Coerces legacy truthiness to the shared boolean checked property.
          # @return [CheckButton] self
          def active=(value)
            write(:checked, !!value)
          end
          alias set_active active=

          protected

          def component_type = :checkbox
          def input_property = :checked
          def signal_map = { 'toggled' => :change, 'clicked' => :change }
        end

        class Button < Widget
          # Creates a literal action label, removing mnemonic underscores when requested.
          # Stock-button IDs are unsupported; no native GTK stock catalog is loaded.
          def initialize(text = nil, label: text, use_underline: true, stock_id: nil)
            super()
            session.refuse(self, :new) unless label.is_a?(String) && stock_id.nil?
            @props[:label] = use_underline ? label.delete('_') : label
          end

          # Reads the retained action label.
          # @return [String]
          def label = read(:label)

          # Writes literal action text through the shared button contract.
          # @return [Button] self
          def label=(value)
            write(:label, String(value))
          end

          protected

          def component_type = :button
          def signal_map = { 'clicked' => :activate }
        end

        # eforgery tests this class while saving ordinary entries. No accepted
        # path constructs one yet, so the constant exists but construction is
        # refused until a measured radio-group consumer establishes semantics.
        class RadioButton < CheckButton
          # Refuses construction until a supported radio-group consumer defines its semantics.
          # @raise [UnsupportedOperation] always
          def initialize(*)
            super()
            Gtk.session.refuse(self, :new)
          end
        end
      end
    end
  end
end
