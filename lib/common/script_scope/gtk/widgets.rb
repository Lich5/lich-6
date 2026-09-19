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

          def initialize
            @session = Gtk.session
            @props = {}
            @children = []
            @signals = {}
            @committed = {}
            @handle = nil
            @destroyed = false
          end

          def method_missing(name, *, **, &)
            session.refuse(self, name)
          end

          # GTK returns a collection snapshot. A source may remove each child
          # while iterating that snapshot without skipping alternating entries.
          def children = @children.dup

          def remove(child)
            session.refuse(self, :remove) unless child.parent.equal?(self)
            session.port.detach(@handle, child.materialize) if @handle
            @children.delete(child)
            child.parent = nil
            self
          end

          def respond_to_missing?(*args)
            super
          end

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

          def set_border_width(value)
            write(:margin, Integer(value))
          end
          alias border_width= set_border_width

          def set_width_request(value)
            write(:width, Integer(value))
          end
          alias width_request= set_width_request

          def set_height_request(value)
            write(:height, Integer(value))
          end
          alias height_request= set_height_request

          def set_size_request(width, height)
            set_width_request(width) unless width == -1
            set_height_request(height) unless height == -1
            self
          end

          def set_tooltip_text(value)
            write(:tooltip, String(value))
          end
          alias tooltip_text= set_tooltip_text

          def override_background_color(state, colour)
            session.refuse(self, :override_background_color) unless state == :normal && colour.is_a?(Gdk::RGBA)
            session.degrade(:background_colour, 'widget background colours follow browser theme; displayed values are retained')
            self
          end

          def set_hexpand(value)
            session.refuse(self, :set_hexpand) unless [true, false].include?(value)
            session.degrade(:expansion, 'available space is distributed by browser layout')
            self
          end
          alias set_vexpand set_hexpand

          def set_margin_left(value)
            write(:margin, (@props[:margin].is_a?(Hash) ? @props[:margin] : {}).merge(left: value))
          end

          def set_margin_right(value)
            write(:margin, (@props[:margin].is_a?(Hash) ? @props[:margin] : {}).merge(right: value))
          end

          def halign=(value)
            session.refuse(self, :halign=) unless %i[start center end].include?(value)
            write(:align, value)
          end

          def tooltip_markup=(value)
            session.refuse(self, :tooltip_markup=) if value.match?(/<[^>]*>/)
            write(:tooltip, CGI.unescapeHTML(value))
          end

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

          def sensitive? = @sensitive != false

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

          def destroyed? = @destroyed
          def visible? = !@destroyed && @props[:hidden] == false

          def toplevel
            parent ? parent.toplevel : self
          end

          def own_dialog(dialog)
            (@dialogs ||= []) << dialog
          end

          def forget_dialog(dialog)
            @dialogs&.delete(dialog)
          end

          def show
            write(:hidden, false)
          end

          def show_all
            show
            @children.each(&:show_all)
            self
          end

          def destroy
            return self if @destroyed

            @dialogs&.dup&.each(&:destroy)
            session.port.destroy(@handle) if @handle
            @parent&.send(:forget_child, self)
            @parent = nil
            mark_destroyed
            session.forget(self)
            @destroy_handlers&.each { |handler| handler.call(self) }
            self
          end

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

          def read(property)
            session.synchronize do
              if property == input_property && @handle && !@destroyed && session.in_callback?
                session.with_widget(self) { session.port.get(@handle, property) }
              else
                @committed.fetch(property, @props[property])
              end
            end
          end

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

          def bind_event(event)
            widget = self
            session.port.bind(@handle, event, proc do |context|
              session.callback(context, terminal: %i[activate submit].include?(event), widget: widget) do
                result = @signals[event]&.call(widget)
                widget.destroy if event == :close && result != true
              end
            end)
          end
        end

        class Window < Widget
          TOPLEVEL = :toplevel
          Allocation = Data.define(:width, :height)

          def initialize(kind = :toplevel)
            super()
            session.refuse(self, :new) unless kind == :toplevel || kind.is_a?(String)
            @props[:title] = kind.is_a?(String) ? kind : ''
            session.register(self)
          end

          def title=(value)
            write(:title, String(value))
          end
          alias set_title title=

          def title = read(:title)

          def resize(width, height)
            write(:size, [Integer(width), Integer(height)])
          end
          alias set_default_size resize

          # sloot restores its saved dimensions with independent setters.
          def default_width=(value)
            resize(value, (@props[:size] || [0, 0])[1])
          end

          def default_height=(value)
            resize((@props[:size] || [0, 0])[0], value)
          end

          def present
            show_all
            session.degrade(:present, 'raising an existing window is controlled by the browser host')
            self
          end

          def set_window_position(value)
            session.refuse(self, :set_window_position) unless value == :center
            session.degrade(:window_position, 'initial placement is controlled by the browser host')
            self
          end

          def move(x, y)
            write(:position, [Integer(x), Integer(y)])
          end

          def position = read(:position) || [0, 0]

          def allocation
            session.degrade(:allocation, 'reports requested size; live browser geometry is not synchronously available')
            Allocation.new(*(@props[:size] || [0, 0]))
          end

          def resizable=(value)
            session.refuse(self, :resizable=) unless value == true || value == false
            session.degrade(:resizable, 'window resizing is controlled by the browser host')
          end

          def set_icon(_icon)
            session.degrade(:window_icon, 'browser window icons are host-controlled')
            self
          end
          alias icon= set_icon

          def keep_above=(value)
            session.refuse(self, :keep_above=) unless value == true || value == false
            session.degrade(:keep_above, 'always-on-top is unsupported by the browser host') if value
          end

          # Window borders belong to its content, not the page schema.
          def set_border_width(value)
            @content_margin = Integer(value)
            self
          end
          alias border_width= set_border_width

          def show_all
            @children.each { |child| child.set_border_width(@content_margin) } if @content_margin
            materialize
            self
          end

          protected

          def component_type = :page
          def signal_map = { 'delete_event' => :close }
          def builtin_events = [:close]
        end

        class Box < Widget
          def initialize(orientation = :horizontal, spacing = 0)
            super()
            # sloot uses GTK's numeric vertical enum in its Save button box.
            orientation = { 0 => :horizontal, 1 => :vertical }.fetch(orientation, orientation)
            session.refuse(self, :new) unless %i[horizontal vertical].include?(orientation)
            @orientation = orientation
            @end_children = []
            @props[:gap] = Integer(spacing)
          end

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
          def initialize(xalign, yalign, xscale, yscale)
            super()
            session.refuse(self, :new) unless [xalign, yalign, xscale, yscale].all? { |value| value.is_a?(Numeric) && value.between?(0, 1) }
            @props[:align] = xalign == 1 ? :end : (xalign.zero? ? :start : :center)
          end

          def set_padding(top, bottom, left, right)
            write(:margin, { top: top, bottom: bottom, left: left, right: right })
          end

          protected

          def component_type = :stack
        end

        class Frame < Widget
          def initialize(label = '')
            super()
            @props[:label] = label
          end

          def set_label_widget(label)
            write(:label, label.text)
          end

          protected

          def component_type = :group
        end

        class Notebook < Widget
          def initialize
            super
            @props[:names] = []
            @props[:selected] = 0
          end

          def set_show_border(value)
            session.refuse(self, :set_show_border) unless value == true || value == false
            session.degrade(:notebook_border, 'tab border styling follows the browser theme')
            self
          end
          alias show_border= set_show_border

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
          def initialize(text = '')
            super()
            @props[:content] = text.to_s
          end

          def text = read(:content)

          def text=(value)
            write(:content, String(value))
          end
          alias set_text text=

          def set_alignment(horizontal, vertical)
            session.refuse(self, :set_alignment) unless [horizontal, vertical].all? { |value| value.is_a?(Numeric) && value.between?(0, 1) }
            write(:align, horizontal.zero? ? :start : (horizontal == 1 ? :end : :center))
          end

          def set_selectable(value)
            session.refuse(self, :set_selectable) unless [true, false].include?(value)
            session.degrade(:text_selection, 'browser text remains selectable') unless value
            self
          end

          def set_markup(value)
            # The measured boon tip uses one bold blue span. Carry its emphasis,
            # declare the arbitrary-colour loss, and never forward source HTML.
            if (tip = value.match(/\A<span color="blue" weight="bold">([^<>]*)<\/span>\z/m))
              session.degrade(:markup_colour, 'arbitrary markup colour follows the browser theme')
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

          def set_wrap(value) = write(:wrap, value)
          alias wrap= set_wrap

          def set_padding(x, y)
            write(:margin, [Integer(x), Integer(y)].max)
          end

          def set_width_chars(count)
            session.refuse(self, :set_width_chars) unless count.is_a?(Integer) && count.between?(1, 512)
            session.degrade(:character_width, 'character width is an initial hint using the browser font')
            write(:width, count * 8)
          end

          protected

          def component_type = :text
        end

        class Entry < Widget
          def initialize
            super
            @props[:value] = ''
            @editable = true
          end

          def text = read(:value)

          def text=(value)
            write(:value, String(value))
          end
          alias set_text text=

          def placeholder_text=(value)
            write(:placeholder, String(value))
          end

          def xalign=(value)
            session.refuse(self, :xalign=) unless value.is_a?(Numeric) && value.between?(0, 1)
            write(:align, value.zero? ? :start : (value == 1 ? :end : :center))
          end

          def editable=(value)
            session.refuse(self, :editable=) if @handle
            @editable = !!value
          end

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
            @editable ? super : super.except(:value).merge(content: @props[:value])
          end
        end

        class CheckButton < Widget
          def initialize(label = '')
            super()
            @props.merge!(label: label, checked: false)
          end

          def active? = read(:checked)

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
          def initialize(text = nil, label: text, use_underline: true, stock_id: nil)
            super()
            session.refuse(self, :new) unless label.is_a?(String) && stock_id.nil?
            @props[:label] = use_underline ? label.delete('_') : label
          end

          def label = read(:label)

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
          def initialize(*)
            super()
            Gtk.session.refuse(self, :new)
          end
        end
      end
    end
  end
end
