# frozen_string_literal: true

require 'cgi'
require 'rexml/document'
require 'uri'
require_relative 'label_markup'

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Marker for supported legacy containers. Iteration exposes a snapshot
        # of actual children; sensitivity is inherited through the shared component tree.
        module Container
          def each(&block) = children.each(&block)
        end

        # Shadow objects preserve synchronous reads and GTK mutator chaining.
        # Only materialized widgets own opaque port handles. Destruction removes
        # the browser surface while leaving Ruby metadata readable, as MyFletch
        # reads and normalizes its entries after destroying the setup window.
        class Widget
          SIGNAL_ID_MUTEX = Mutex.new
          private_constant :SIGNAL_ID_MUTEX

          # IDs are unique across widgets; a foreign widget's ID cannot remove
          # a coincidentally numbered local connection. They never cross the wire.
          def self.next_signal_id
            SIGNAL_ID_MUTEX.synchronize { @signal_sequence = (@signal_sequence || 0) + 1 }
          end
          private_class_method :next_signal_id

          attr_reader :session, :parent
          attr_writer :placement

          # Creates script-owned shadow state without allocating a browser control.
          def initialize
            @session = Gtk.session
            @props = {}
            @children = []
            @signals = {}
            @signal_connections = {}
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

          # Retains GTK's widget name as script metadata, distinct from Builder
          # identity. Names never become DOM IDs, classes or CSS selectors.
          # @return [String] explicit name or the GTK class name
          def name = @widget_name || "Gtk#{self.class.name.to_s.split('::').last}"

          # @param value [String] bounded literal name, at most 512 characters
          # @return [Widget] self
          def set_name(value)
            session.refuse(self, :name=) unless value.is_a?(String) && value.length <= 512
            @widget_name = value.dup.freeze
            session.refresh_label_styles
            self
          end
          alias name= set_name

          # Uses the existing show/hide lifecycle for the property spelling.
          # @param value [Boolean] requested visibility
          def visible=(value)
            session.refuse(self, :visible=) unless [true, false].include?(value)
            value ? show : hide
          end

          # Detaches a child from this widget while retaining its shadow state and handle.
          # @return [Widget] self
          # @raise [UnsupportedOperation] unless this widget is its parent
          def remove(child)
            session.refuse(self, :remove) if @tab_owner
            session.refuse(self, :remove) unless child.parent.equal?(self)
            session.port.detach(@handle, child.materialize) if @handle
            @children.delete(child)
            child.parent = nil
            session.refresh_label_styles
            refresh_layout!
            self
          end

          # Does not advertise unsupported native widget methods through reflection.
          # @return [Boolean]
          def respond_to_missing?(*args)
            super
          end

          # Applies bounded generic-family typography to text and ordinary controls.
          # @param font [Pango::FontDescription] parsed family/size plus normal/bold weight
          # @return [Widget] self
          # @raise [UnsupportedOperation] for widgets without a text-style contract
          def override_font(font)
            valid = font.is_a?(Pango::FontDescription) && %i[text button text_input].include?(component_type)
            session.refuse(self, :override_font) unless valid
            font.properties.each { |property, value| write(property, value) }
            write(:emphasis, font.weight == :bold ? :strong : :normal)
          end

          # Returns the widget-local decoration facade without exposing DOM styling.
          # @return [StyleContext]
          def style_context
            session.style_operation(self, :style_context) do
              session.refuse(self, :style_context) if destroyed?
              @style_context ||= StyleContext.new(self)
            end
          end

          # Appends a same-session child through the shared single-parent/cycle checks.
          # @return [Widget] self
          def add(child)
            insert_child(child, @children.length)
          end

          # GTK moves a negative or past-end position to the final child. This
          # also preserves Glade packing positions with omitted placeholder slots.
          def reorder_child(child, index)
            session.refuse(self, :reorder_child) unless child.parent.equal?(self) && index.is_a?(Integer)
            session.synchronize do
              @children.delete(child)
              index = @children.length if index.negative? || index > @children.length
              @children.insert(index, child)
              if @handle
                session.port.detach(@handle, child.materialize)
                session.port.attach(@handle, child.materialize, index)
              end
              refresh_layout!
            end
            self
          end

          def insert_child(child, index, placement: nil)
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
            if @handle
              if placement
                session.port.attach(@handle, child.materialize, index, placement: placement)
              else
                session.port.attach(@handle, child.materialize, index)
              end
            end
            child.parent = self
            @children.insert(index, child)
            session.refresh_label_styles
            refresh_layout!
            self
          end
          private :insert_child

          # Maps accepted legacy signals to core events; destroy handlers accumulate separately.
          # @return [Integer] stable connection ID, shared across this widget's signal families
          # @raise [UnsupportedOperation] for an unmapped signal
          def signal_connect(name, &block)
            raise ArgumentError, 'signal handler is required' unless block

            session.style_operation(self, :signal_connect) do
              session.refuse(self, :signal_connect) if destroyed?
              name = name.to_s.tr('-', '_')
              event = if name == 'destroy'
                        :destroy
                      elsif name == 'button_press_event'
                        session.refuse(self, "signal:#{name}") unless session.port.schema(component_type)[:events].key?(:pointer_press)
                        write(:pointer_events, true)
                        :pointer_press
                      else
                        signal_map.transform_keys { |key| key.tr('-', '_') }[name] || session.refuse(self, "signal:#{name}")
                      end
              id = Widget.send(:next_signal_id)
              # The guard also suppresses a disconnected handler already present
              # in an emission snapshot, without disturbing other listeners.
              handler = proc { |*args| block.call(*args) if @signal_connections.key?(id) }
              if event == :destroy
                (@destroy_handlers ||= []) << handler
              else
                (@signals[event] ||= []) << [name, handler]
                bind_event(event) if @handle
              end
              @signal_connections[id] = [event, handler]
              id
            end
          end

          # Removes exactly one local connection, retaining the internal lifecycle
          # binding (including geometry observation). Unknown/reused IDs refuse.
          # @return [Widget] self
          def disconnect_signal_handler(id)
            session.style_operation(self, :signal_handler_disconnect) do
              connection = @signal_connections[id] if id.is_a?(Integer)
              session.refuse(self, :signal_handler_disconnect) if (destroyed? && !@emitting_destroy) || !connection
              event, handler = @signal_connections.delete(id)
              if event == :destroy
                @destroy_handlers.delete(handler)
              else
                @signals.fetch(event).delete_if { |_name, callback| callback.equal?(handler) }
              end
            end
            self
          end
          private :disconnect_signal_handler

          # Enables only the pointer-press mask on contracted pointer surfaces.
          # Other native event families are not implied by menu support.
          # @return [Widget] self
          def add_events(mask)
            session.refuse(self, :add_events) unless mask == Gdk::EventMask::BUTTON_PRESS_MASK && session.port.schema(component_type)[:events].key?(:pointer_press)
            write(:pointer_events, true)
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

          # Reads retained literal tooltip metadata, including an unset nil value.
          # @return [String, nil] current tooltip text
          def tooltip_text = read(:tooltip)
          alias get_tooltip_text tooltip_text

          # Accepts the measured normal-state token while retaining browser-theme backgrounds.
          # @return [Widget] self
          # @raise [UnsupportedOperation] for other state/color objects
          def override_background_color(state, colour)
            session.refuse(self, :override_background_color) unless state == :normal && colour.is_a?(Gdk::RGBA)
            session.degrade(:background_colour, 'widget background colours follow browser theme; displayed values are retained')
            self
          end

          # Labels project bounded foreground colors; control captions remain theme-owned.
          # @return [Widget] self
          # @raise [UnsupportedOperation] for unknown states, colors, widgets or owner/lifetime misuse
          def override_color(state, colour)
            session.style_operation(self, :override_color) do
              session.refuse(self, :override_color) if destroyed? || state != StateFlags::NORMAL || !colour.is_a?(Gdk::RGBA)
              if is_a?(Label) && !@link_markup
                write(:foreground, @label_color || colour.to_h)
                @props[:foreground] = colour.to_h
              elsif is_a?(Button) || is_a?(ToggleButton) || is_a?(Entry)
                session.degrade(:control_foreground, 'control caption colors follow the WebUI theme', receiver: self)
              else
                session.refuse(self, :override_color)
              end
            end
            self
          end

          # Retains explicit expansion; otherwise containers inherit descendant demand.
          # Horizontal grids use existing expanding tracks and vertical stacks use fill.
          # @return [Widget] self
          def set_hexpand(value)
            session.refuse(self, :set_hexpand) unless [true, false].include?(value)
            session.synchronize do
              @hexpand = value
              refresh_layout!
            end
            self
          end
          alias hexpand= set_hexpand

          # Requests available height through the same bounded layout propagation.
          # @return [Widget] self
          def set_vexpand(value)
            session.refuse(self, :set_vexpand) unless [true, false].include?(value)
            session.synchronize do
              @vexpand = value
              refresh_layout!
            end
            self
          end
          alias vexpand= set_vexpand

          # @api private
          # @return [Boolean] explicit or descendant expansion along the given axis
          def expands?(axis)
            explicit = axis == :horizontal ? @hexpand : @vexpand
            explicit.nil? ? @children.any? { |child| child.expands?(axis) } : explicit
          end

          # Recompute only layout properties after a structural/expansion change.
          # Existing adapter handles and viewer-local input remain intact.
          # @api private
          def refresh_layout!
            root = toplevel
            return unless root.instance_variable_get(:@handle)
            pending = [root]
            until pending.empty?
              widget = pending.pop
              handle = widget.instance_variable_get(:@handle)
              if handle && !widget.destroyed?
                props = widget.send(:layout_props)
                previous = widget.instance_variable_get(:@published_layout) || {}
                props.each { |key, value| session.port.set(handle, key, value) unless previous[key] == value }
                widget.instance_variable_set(:@published_layout, props)
              end
              pending.concat(widget.children)
            end
          end

          # Replaces all edges through the existing bounded margin contract.
          # @param value [Integer] margin in pixels, 0..512
          # @return [Widget] self
          def set_margin(value)
            session.refuse(self, :margin=) unless value.is_a?(Integer) && value.between?(0, 512)
            write(:margin, value)
          end
          alias margin= set_margin

          # Updates the left entry of the widget's explicit per-side margin.
          # @return [Widget] self
          def set_margin_left(value)
            set_margin_edge(:left, value)
          end
          alias margin_left= set_margin_left

          # Updates the right entry of the widget's explicit per-side margin.
          # @return [Widget] self
          def set_margin_right(value)
            set_margin_edge(:right, value)
          end
          alias margin_right= set_margin_right

          # Updates one vertical edge without changing the other explicit margins.
          # @param value [Integer] margin in pixels, validated by the shared contract
          def set_margin_top(value)
            set_margin_edge(:top, value)
          end
          alias margin_top= set_margin_top

          # @param value [Integer] bottom margin in pixels
          def set_margin_bottom(value)
            set_margin_edge(:bottom, value)
          end
          alias margin_bottom= set_margin_bottom

          # A scalar margin applies to every edge; changing one preserves the other three.
          # Builder and direct GTK calls share this normalization and contract validation.
          # @api private
          def set_margin_edge(side, value)
            current = margin_value
            margins = case current
                      when Hash then current
                      when Numeric then %i[top right bottom left].to_h { |key| [key, current] }
                      else {}
                      end
            write(:margin, margins.merge(side => value))
          end
          private :set_margin_edge

          # Internal entry facades override the source without changing edge normalization.
          def margin_value = @props[:margin]
          private :margin_value

          # Aligns the widget in its allocated grid cell or enclosing frame.
          # Content alignment (Label#yalign=) is a separate request.
          # @param value [Symbol] :fill, :start, :center or :end
          def valign=(value)
            session.refuse(self, :valign=) unless %i[fill start center end].include?(value)
            alignment = value == :fill ? :stretch : value
            validate_vertical_parent(alignment) if parent
            write(:vertical_align, alignment)
            refresh_layout!
          end
          alias set_valign valign=

          # Maps GTK horizontal fill onto the existing grid stretch allocation.
          # @return [Widget] self
          def halign=(value)
            session.refuse(self, :halign=) unless %i[fill start center end].include?(value)
            write(:align, value == :fill ? :stretch : value)
          end
          alias set_halign halign=

          # Accepts only the focus behavior already provided by this concrete control.
          # Composite entries and non-default requests need their own implementation;
          # disabling focus must never be confused with disabling the whole widget.
          # @param value [Boolean] requested ability to own input focus
          # @return [void]
          # @raise [UnsupportedOperation] when no equivalent control behavior exists
          def can_focus=(value)
            kind = self.class.name&.split('::')&.last
            focusable = %w[Button ToggleButton CheckButton RadioButton Entry ComboEntry SearchEntry SpinButton TextView Notebook ScrolledWindow Expander TreeView ComboBoxText ComboBox]
            passive = %w[Window Box HBox VBox Grid Table Frame Viewport Label Separator HSeparator]
            expected = if focusable.include?(kind) then true
                       elsif passive.include?(kind) then false
                       end
            session.refuse(self, :can_focus=) if expected.nil? || value != expected
          end
          alias set_can_focus can_focus=

          alias set_margin_start set_margin_left
          alias set_margin_end set_margin_right
          alias margin_start= set_margin_start
          alias margin_end= set_margin_end

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

          # Reads effective sensitivity without overwriting a child's own setting.
          # @return [Boolean] false when this widget or any ancestor is insensitive
          def is_sensitive? = sensitive? && (!parent || parent.is_sensitive?)

          # Creates descendants before the root can publish, then binds supported events once.
          # @return [Lich::WebUI::Adapter::Handle] cached opaque control handle
          def materialize
            session.flush_models!
            return @handle if @handle

            # Build descendants before the page starts scheduling delivery. A
            # long script constructor must not publish a half-built window.
            child_handles = @children.map(&:materialize)
            @handle = session.port.create(component_type, component_props.merge(placement: @placement || {}))
            @published_layout = layout_props
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

          # Hides widget content without discarding its input or destroying its owner.
          # @return [Widget] self
          def hide
            write(:hidden, true)
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
            session.synchronize do
              return self if @destroyed

              # Keep handle retirement and provider detachment atomic with reloads.
              @dialogs&.dup&.each { |dialog| session.cleanup(dialog) { dialog.destroy } }
              @tab_owner&.send(:retire_header, self)
              session.port.destroy(@handle) if @handle
              @parent&.send(:forget_child, self)
              @parent = nil
              mark_destroyed
              session.forget(self)
              self
            end
          end

          # Marks the shadow subtree retired while preserving script-readable metadata.
          # @return [void]
          def mark_destroyed
            return if @destroyed

            @destroyed = true
            @style_context&.send(:close)
            @children.dup.each(&:mark_destroyed)
            begin
              @emitting_destroy = true
              @destroy_handlers&.dup&.each { |handler| session.cleanup(self) { handler.call(self) } }
            ensure
              @emitting_destroy = false
              @signal_connections.clear
              @signals.clear
              @destroy_handlers&.clear
            end
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
            refresh_layout!
          end

          # Do not mistake a vertical flex container's horizontal cross axis for
          # vertical allocation. Only natural-height start alignment is supported
          # there; single-child scrollers own a separate grid allocation.
          def component_props
            validate_vertical_parent(@props[:vertical_align]) if @props.key?(:vertical_align) && parent
            @props.merge(layout_props)
          end

          def validate_vertical_parent(alignment)
            supported = parent.is_a?(Table) || parent.is_a?(Frame) || parent.is_a?(Overlay) ||
                        (parent.is_a?(ScrolledWindow) && parent.children.length == 1) ||
                        (parent.is_a?(Box) && (!parent.vertical? || (alignment == :start && !expands?(:vertical))))
            session.refuse(self, :valign_parent) unless supported
          end

          def layout_props = {}
          def signal_map = {}
          def input_property = nil
          def builtin_events = []

          # Reads current viewer input only inside a live callback; otherwise uses committed/default shadow state.
          # @return [Object] synchronous script-visible value
          def read(property)
            session.synchronize do
              session.flush_models!
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
              session.flush_models!
              @tab_owner&.send(:header_will_change, self, property, value)
              # A rejected port write must leave synchronous script reads at
              # their last valid value, including after window destruction.
              session.with_widget(self) { session.port.set(@handle, port_property(property), value) } if @handle && !@destroyed
              if property == input_property && @committed.key?(property)
                @committed[property] = value
              else
                @props[property] = value
              end
              @tab_owner&.send(:refresh_headers)
            end
            self
          end

          def port_property(property) = property

          # Calls handlers in connection order; a true close result vetoes default destruction.
          # @return [Object, nil] last handler result, or the first close veto
          def emit_handlers(event, signal: nil)
            result = nil
            @signals.fetch(event, []).dup.each do |name, handler|
              next if signal && name != signal

              result = handler.call(self)
              break if event == :close && result == true
            end
            result
          end

          # Commits terminal input before invoking legacy save/close handlers.
          # @param event [Symbol] shared-control event mapped to a GTK signal
          # @return [String] adapter binding identifier
          # @api private
          def bind_event(event)
            widget = self
            session.port.bind(@handle, event, proc do |context|
              session.callback(context, terminal: !context.viewer_id.nil? && %i[activate submit close].include?(event), widget: widget) do
                result = if event == :pointer_press
                           pointer = PointerEvent.new(**context.payload)
                           session.with_pointer(widget, pointer) do
                             @signals.fetch(event, []).dup.each do |_name, handler|
                               break if handler.call(widget, pointer) == true
                             end
                           end
                         else
                           widget.send(:emit_handlers, event)
                         end
                widget.destroy if event == :close && result != true
              end
            end)
          end
        end

        class Window < Widget
          include Container

          attr_reader :titlebar

          TOPLEVEL = :toplevel
          Allocation = Data.define(:width, :height)

          # Creates a compact window inheriting the application's GTK preference.
          # @param kind [Symbol, String] :toplevel, legacy :TOPLEVEL, or the window title
          def initialize(kind = :toplevel)
            super()
            kind = :toplevel if kind == :TOPLEVEL
            session.refuse(self, :new) unless kind == :toplevel || kind.is_a?(String)
            @props[:title] = kind.is_a?(String) ? kind : ''
            @props.merge!(bare: true, density: :compact)
            session.register(self)
          end

          # Requests focus for a live same-owner descendant through the core facility.
          # Before show, the request is retained until the page and its inputs exist.
          # @return [Window] self
          # @raise [UnsupportedOperation] for foreign, detached or retired targets
          def set_focus(widget)
            valid = !destroyed? && widget.is_a?(Widget) && widget.session.equal?(session) && !widget.destroyed?
            valid &&= Lich::WebUI::TreeBuilder::FOCUSABLE_TYPES.include?(widget.send(:component_type))
            ancestor = widget if valid
            ancestor = ancestor.parent while ancestor && !ancestor.equal?(self)
            session.refuse(self, :set_focus) unless valid && ancestor.equal?(self)
            session.synchronize do
              if @handle
                session.port.focus(@handle, widget.materialize)
              else
                @initial_focus = widget
              end
            end
            self
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

          # A HeaderBar is a separate first child; the normal content stays intact.
          # Live replacement preserves both the page handle and detached titlebar.
          def set_titlebar(bar)
            session.synchronize do
              session.refuse(self, :set_titlebar) if destroyed?
              session.refuse(self, :set_titlebar) unless bar.nil? || bar.is_a?(HeaderBar)
              return self if bar.equal?(@titlebar)

              if bar
                valid = bar.is_a?(HeaderBar) && bar.session.equal?(session) && !bar.destroyed? && !bar.parent
                session.refuse(self, :set_titlebar) unless valid && !toplevel.equal?(bar)
                insert_child(bar, 0)
              end
              remove(@titlebar) if @titlebar
              @titlebar = bar
            end
            self
          end
          alias titlebar= set_titlebar

          def remove(child)
            super
            @titlebar = nil if child.equal?(@titlebar)
            self
          end

          # Programmatic and header closes follow the existing owner dispatcher.
          # A true delete-event result vetoes destruction; destroyed windows are inert.
          def close
            return self if destroyed?

            session.queue { destroy unless destroyed? || emit_handlers(:close) == true }
            self
          end

          # Requests integer window dimensions through the shared page size property.
          # @return [Window] self
          def resize(width, height)
            write(:size, [Integer(width), Integer(height)])
          end
          alias set_default_size resize

          # GTK window requisitions are minimum client sizes, not fixed HTML widths.
          # Both positive minima supply an initial size when no explicit resize exists;
          # a single minimum leaves the other axis under host/user control.
          # @return [Window] self
          def set_width_request(value)
            write(:min_width, Integer(value))
            refresh_layout!
            self
          end
          alias width_request= set_width_request

          # @return [Window] self
          def set_height_request(value)
            write(:min_height, Integer(value))
            refresh_layout!
            self
          end
          alias height_request= set_height_request

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

          alias set_position set_window_position

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
            session.synchronize do
              unless destroyed?
                dimensions = allocation
                @observed_geometry = { width: dimensions.width, height: dimensions.height, position: position }
              end
              super
            end
          end

          # Validates the legacy flag and reports that window resizing is host-controlled.
          # @raise [UnsupportedOperation] for nonboolean values
          def resizable=(value)
            session.refuse(self, :resizable=) unless value == true || value == false
            session.degrade(:resizable, 'window resizing is controlled by the browser host')
          end
          alias set_resizable resizable=

          # Utility classification does not change focus, ownership or native window lifetime.
          # @return [Window] self
          def set_type_hint(value)
            session.refuse(self, :set_type_hint) unless value == Gdk::WindowTypeHint::UTILITY
            session.degrade(:window_type_hint, 'utility window classification is controlled by the browser host')
            self
          end
          alias type_hint= set_type_hint

          # Reports the host-owned window-icon limitation without loading native image objects.
          # @return [Window] self
          def set_icon(_icon)
            session.degrade(:window_icon, 'browser window icons are host-controlled')
            self
          end
          alias icon= set_icon

          # Browser setup windows remain independently interactive. Retain the GTK
          # hint, but report that blocking peer windows is not implemented here;
          # this does not alter owner isolation or impose a window-count limit.
          # @param value [Boolean] requested GTK modality
          def modal=(value)
            session.refuse(self, :modal=) unless [true, false].include?(value)
            @modal = value
            session.degrade(:window_modal, 'GTK window modality is ignored; setup windows remain independently interactive') if value
          end
          alias set_modal modal=

          # @return [Boolean] retained request, not a claim of host enforcement
          def modal? = @modal == true

          # Requests native topmost behavior through the shared presentation contract.
          # Unsupported hosts retain the request and report their normal degradation.
          # @param value [Boolean] whether to keep this window above ordinary windows
          # @return [void]
          def keep_above=(value)
            session.refuse(self, :keep_above=) unless value == true || value == false
            write(:presentation, (@props[:presentation] || {}).merge(always_on_top: value))
          end
          alias set_keep_above keep_above=

          # Requests native chrome using the existing bounded presentation contract.
          # Browser-only hosts retain the request with their normal host limitation.
          # @param value [Boolean] whether to retain window decorations
          # @return [Window] self
          def set_decorated(value)
            session.refuse(self, :decorated=) unless [true, false].include?(value)
            session.synchronize do
              write(:presentation, (@props[:presentation] || {}).merge(borderless: !value))
            end
          end
          alias decorated= set_decorated

          # @return [Boolean] requested decoration state; true by default
          def decorated? = !read(:presentation)&.fetch(:borderless, false)

          # Window borders belong to its content, not the page schema.
          def set_border_width(value)
            @content_margin = Integer(value)
            self
          end
          alias border_width= set_border_width

          # Applies content margins and materializes this page for the shared publication path.
          # @return [Window] self
          def show_all
            @children.each { |child| child.set_border_width(@content_margin) unless child.equal?(@titlebar) } if @content_margin
            @children.each(&:show_all)
            show
          end

          # Publishes the window through its existing owner lifecycle.
          # @return [Window] self
          def show
            session.synchronize do
              session.refuse(self, :show) if destroyed?
              write(:presentation, @props[:presentation].merge(hidden: false)) if @props.dig(:presentation, :hidden)
              materialize
              if @initial_focus
                target, @initial_focus = @initial_focus, nil
                unless target.destroyed?
                  ancestor = target
                  ancestor = ancestor.parent while ancestor && !ancestor.equal?(self)
                  set_focus(target) if ancestor.equal?(self)
                end
              end
              @shown = true
            end
            self
          end

          # Hides the owned host window without retiring the page or its inputs.
          # Browser hosts hide page content and report the chrome limitation.
          # @return [Window] self
          def hide
            session.synchronize do
              session.refuse(self, :hide) if destroyed?
              write(:presentation, (@props[:presentation] || {}).merge(hidden: true))
              @shown = false
            end
            self
          end

          # Requests real native minimization without retiring the page.
          # @return [Window] self
          def iconify
            request_minimized(true)
          end

          # Restores the owned native window through its presentation channel.
          # @return [Window] self
          def deiconify
            request_minimized(false)
          end

          # A new request can repeat a value after the user changed the actual native state.
          def request_minimized(value)
            session.synchronize do
              revision = (@minimize_revision || 0) + 1
              session.refuse(self, :iconify) if revision > 2_147_483_647
              write(:presentation, (@props[:presentation] || {}).merge(minimized: value, minimized_revision: revision))
              @minimize_revision = revision
            end
            self
          end
          private :request_minimized

          # @return [Boolean] whether this window has been published and remains live
          def visible? = !destroyed? && @shown == true

          # Removes a standard window signal, including destroy, without retiring
          # its core geometry/close observers. Other facade signal families retain
          # their existing capability boundaries.
          # @return [Window] self
          def signal_handler_disconnect(id) = disconnect_signal_handler(id)

          protected

          def component_type = :page

          def forget_child(child)
            @titlebar = nil if child.equal?(@titlebar)
            super
          end

          def layout_props
            props = { viewport: expands?(:vertical) }
            if !@props.key?(:size) && @props.fetch(:min_width, 0).positive? && @props.fetch(:min_height, 0).positive?
              props[:size] = [@props[:min_width], @props[:min_height]]
            end
            props
          end

          def signal_map = { 'delete_event' => :close, 'configure_event' => :configure, 'window_state_event' => :window_state }
          def builtin_events = %i[close configure window_state]

          # Preserve the latest validated browser measurements for the original
          # script's allocation/position reads, including its exit cleanup.
          def bind_event(event)
            if event == :window_state
              return session.port.bind(@handle, event, proc do |context|
                session.callback(context, widget: self) do
                  minimized = context.payload.fetch(:minimized)
                  previous = @observed_minimized || false
                  @observed_minimized = minimized
                  next if previous == minimized

                  state = WindowStateEvent.new(new_window_state: minimized ? Gdk::WindowState::ICONIFIED : 0,
                                               changed_mask: Gdk::WindowState::ICONIFIED)
                  @signals.fetch(:window_state, []).dup.each do |_name, handler|
                    break if destroyed? || handler.call(self, state) == true
                  end
                end
              end)
            end
            return super unless event == :configure

            session.port.bind(@handle, :configure, proc do |context|
              session.callback(context, widget: self) do
                previous = @observed_geometry
                @observed_geometry = context.payload.merge(position: context.payload.fetch(:position).dup.freeze).freeze
                geometry = @observed_geometry.values_at(:width, :height, :position)
                next if previous && previous.values_at(:width, :height, :position) == geometry

                event = ConfigureEvent.new(width: geometry[0], height: geometry[1], x: geometry[2][0], y: geometry[2][1])
                @signals.fetch(:configure, []).dup.each do |_name, handler|
                  break if destroyed? || handler.call(self, event) == true
                end
              end
            end)
          end
        end

        # Immutable notification data from the existing validated viewer geometry.
        ConfigureEvent = Data.define(:width, :height, :x, :y)
        WindowStateEvent = Data.define(:new_window_state, :changed_mask)

        class Box < Widget
          include Container

          # @api private
          def vertical? = @orientation == :vertical

          # Creates a horizontal grid or vertical stack with the requested spacing.
          # Numeric orientation 0/1 is accepted for the measured GTK enum usage.
          def initialize(orientation = :horizontal, spacing = 0)
            super()
            # sloot uses GTK's numeric vertical enum in its Save button box.
            orientation = { 0 => :horizontal, 1 => :vertical }.fetch(orientation, orientation)
            session.refuse(self, :new) unless %i[horizontal vertical].include?(orientation)
            @orientation = orientation
            @end_children = []
            @packing = {}.compare_by_identity
            @props[:gap] = Integer(spacing)
          end

          # Forget packing metadata when a live child is detached for reuse.
          def remove(child)
            super
            @packing.delete(child)
            self
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

          def forget_child(child)
            @packing.delete(child)
            super
          end

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
              @packing[child] = { expand: expand, fill: fill }
              refresh_layout!
            end
            self
          end

          def component_type = vertical? && !@homogeneous ? :stack : :grid

          # Natural tracks keep long captions from spilling into equal-width peers.
          # Expanded children share surplus width; their own alignment still applies.
          def layout_props
            return {} unless %i[stack grid].include?(component_type)
            if vertical?
              return { cols: 1, equal_rows: true } if @homogeneous

              allocated = parent.is_a?(Window) || (parent.is_a?(Box) && parent.vertical?)
              { fill: !!(allocated && expands?(:vertical)) }
            else
              expanding = @children.each_index.select do |index|
                child = @children[index]
                child.expands?(:horizontal) || @packing.dig(child, :expand) == true
              end.map { |index| index + 1 }
              { cols: [@children.length, 1].max, homogeneous: @homogeneous == true, expand_columns: expanding }
            end
          end
        end

        # Measured horizontal action rows use natural tracks aligned to the end.
        # Other GTK ButtonBox layouts remain explicit unsupported operations.
        class ButtonBox < Box
          def initialize(orientation = :horizontal)
            super(orientation)
            session.refuse(self, :new) if vertical?
            @props[:align] = :end
          end

          def layout = read(:align)

          # @param value [Symbol] the measured :end layout
          # @return [ButtonBox] self
          def set_layout(value)
            session.refuse(self, :layout=) unless value == :end
            write(:align, value)
          end
          alias layout= set_layout

          def spacing = read(:gap)

          # @param value [Integer] inter-button gap in pixels, 0..64
          # @return [ButtonBox] self
          def set_spacing(value)
            session.refuse(self, :spacing=) unless value.is_a?(Integer) && value.between?(0, 64)
            write(:gap, value)
          end
          alias spacing= set_spacing

          # Use Box's live grid growth before admitting another button.
          def add(child)
            pack_start(child, expand: false, fill: false)
          end

          protected

          def layout_props = super.merge(expand_columns: [])
        end

        # Legacy horizontal constructor using the existing Box packing contract.
        class HBox < Box
          # Creates a horizontal group with optional equal-width tracks.
          # @param homogeneous [Boolean] whether children share equal widths
          # @param spacing [Integer] gap between children in shared layout units
          # @raise [UnsupportedOperation] when homogeneous is not boolean
          def initialize(homogeneous = false, spacing = 0)
            super(:horizontal, spacing)
            session.refuse(self, :new) unless [true, false].include?(homogeneous)
            @homogeneous = homogeneous
          end
        end

        # Legacy vertical constructor using the existing Box packing contract.
        class VBox < Box
          # Creates a vertical group with optional equal-height grid rows.
          # @param homogeneous [Boolean] whether children share equal heights
          # @param spacing [Integer] gap between children in shared layout units
          # @raise [UnsupportedOperation] when homogeneous is not boolean
          def initialize(homogeneous = false, spacing = 0)
            super(:vertical, spacing)
            session.refuse(self, :new) unless [true, false].include?(homogeneous)
            @homogeneous = homogeneous
          end
        end

        class Alignment < Widget
          include Container

          # Matches GTK's finite-value clamping before projecting horizontal alignment.
          # Vertical fractions/scaling remain layout hints, not a full GTK allocator.
          # @raise [UnsupportedOperation] for non-real or nonfinite numeric inputs
          def initialize(xalign, yalign, xscale, yscale)
            super()
            values = [xalign, yalign, xscale, yscale]
            session.refuse(self, :new) unless values.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? }
            xalign = values.map { |value| value.clamp(0, 1) }.first
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
          include Container

          # A frame's requested width is a minimum; it must still contain its
          # child's natural requisition instead of clipping the grid decoration.
          def set_width_request(value)
            write(:min_width, Integer(value))
          end
          alias width_request= set_width_request

          # Height requests likewise set a floor, allowing the child's natural
          # height to grow the frame instead of centering overflow above it.
          def set_height_request(value)
            write(:min_height, Integer(value))
          end
          alias height_request= set_height_request

          # GTK creates no label widget when the constructor label is absent.
          # @param label [String, nil] frame label; an empty string creates a blank label
          def initialize(label = nil)
            super()
            set_label(label) unless label.nil?
          end

          # @return [String, nil] caption, preserving absent and explicitly empty labels
          def label = read(:label)

          # Changes only the shared group caption, preserving children and their identities.
          # @param value [String] literal caption, at most 512 characters
          # @return [Frame] self
          def set_label(value)
            valid = value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? &&
                    value.length <= Lich::WebUI::Contract::BOUNDS[:short_text]
            session.refuse(self, :label=) unless valid
            write(:label, value)
          end
          alias label= set_label

          # Copies the supplied label's text into the shared group label.
          # @return [Frame] self
          def set_label_widget(label)
            set_label(label.text)
          end

          # The shared frame already places its caption at the left edge.
          # @param value [Numeric] only zero is supported
          # @return [void]
          def label_xalign=(value)
            session.refuse(self, :label_xalign=) unless value.is_a?(Numeric) && value.zero?
          end

          # Restores the themed frame border for :in; native inset bevels are omitted.
          # @param value [Symbol] :none or :in
          # @return [Frame] self
          def set_shadow_type(value)
            session.refuse(self, :shadow_type=) unless %i[none in].include?(value)
            write(:border_width, value == :none ? 0 : 1)
            session.degrade(:frame_shadow, 'shadow-type=in uses the themed frame border; native inset bevel omitted') if value == :in
            self
          end
          alias shadow_type= set_shadow_type

          protected

          def component_type = :group

          # A frame aligns its child's natural height within its own allocation.
          # Explicit :start resets an earlier center/end request after live edits.
          def layout_props
            alignment = @children.first&.instance_variable_get(:@props)&.fetch(:vertical_align, nil)
            return {} unless alignment || @published_layout&.key?(:content_align)

            { content_align: alignment && alignment != :stretch ? alignment : :start }
          end
        end

        class Notebook < Widget
          include Container

          # Creates an empty tab set with the first tab selected by default.
          def initialize
            super
            @props[:names] = []
            @props[:selected] = 0
            @tabs = []
            @props[:headers] = []
          end

          # The shared tabs component already places selectors above page content.
          # @param position [Symbol] only :top is supported
          # @return [Notebook] self
          def set_tab_pos(position)
            session.refuse(self, :set_tab_pos) unless position == :top
            self
          end
          alias tab_pos= set_tab_pos

          # Validates the border request and reports theme-controlled tab borders.
          # @return [Notebook] self
          def set_show_border(value)
            session.refuse(self, :set_show_border) unless value == true || value == false
            session.degrade(:notebook_border, 'tab border styling follows the browser theme')
            self
          end
          alias show_border= set_show_border

          # Browser tabs remain reachable through their host's overflow behavior.
          # @return [Notebook] self
          def set_scrollable(value)
            session.refuse(self, :set_scrollable) unless [true, false].include?(value)
            session.degrade(:notebook_scrollable, 'tab overflow follows the browser layout')
            self
          end
          alias scrollable= set_scrollable

          # Legacy tab padding is theme-owned and does not alter page content margins.
          # @return [Notebook] self
          def set_tab_border(value)
            session.refuse(self, :set_tab_border) unless value.is_a?(Integer) && value.between?(0, 65_535)
            session.degrade(:notebook_tab_border, 'tab padding follows the browser theme')
            self
          end
          alias tab_border= set_tab_border

          # Hides only page selectors; the selected page and notebook sizing remain.
          # @param value [Boolean] whether the browser exposes tab buttons
          def show_tabs=(value)
            session.refuse(self, :show_tabs=) unless [true, false].include?(value)
            write(:show_tabs, value)
          end
          alias set_show_tabs show_tabs=

          # Pages require an explicit paired header; generic container mutation
          # cannot bypass the atomic notebook collection path.
          def add(_child) = session.refuse(self, :add)
          def reorder_child(_child, _index) = session.refuse(self, :reorder_child)

          # @return [Integer] number of actual pages, excluding tab-label widgets
          def n_pages = @children.length

          # Selects the last page for GTK's negative spelling, otherwise a bounded index.
          # Live writes use core viewer state, including pages appended in this callback.
          def set_current_page(index)
            session.style_operation(self, :set_current_page) do
              session.refuse(self, :set_current_page) if destroyed? || !index.is_a?(Integer)
              index = n_pages - 1 if index.negative?
              return self unless index.between?(0, n_pages - 1)

              write(:selected, index)
            end
          end

          # Accepts a Label, or one EventBox containing a Label. Headers remain
          # owned widgets but never appear as extra Notebook#children pages.
          def append_page(child, label)
            session.style_operation(self, :append_page) do
              valid = !destroyed? && child.is_a?(Widget) && child.session.equal?(session) && !child.destroyed? && child.parent.nil?
              ancestor = self
              while ancestor
                valid &&= !ancestor.equal?(child)
                ancestor = ancestor.parent
              end
              text = label.is_a?(EventBox) ? label.children.first : label
              valid &&= label.is_a?(Widget) && label.session.equal?(session) && !label.destroyed? && label.parent.nil? &&
                        text.instance_of?(Label) && !text.destroyed? && text.session.equal?(session) && !label.equal?(child) &&
                        !label.instance_variable_get(:@tab_owner) && !text.instance_variable_get(:@tab_owner)
              session.refuse(self, :append_page) unless valid
              entry = { key: "tab-#{SecureRandom.hex(12)}", widget: label, label: text, page: child }
              publish_tabs(@tabs + [entry])
              label.send(:parent=, self)
              [label, text].uniq.each { |widget| widget.instance_variable_set(:@tab_owner, self) }
              child.send(:parent=, self)
              @children << child
              @tabs << entry
              n_pages - 1
            end
          end

          # Detaches a page and its header without destroying reusable widgets.
          def remove_page(index)
            session.style_operation(self, :remove_page) do
              session.refuse(self, :remove_page) if destroyed? || !index.is_a?(Integer)
              index = n_pages - 1 if index.negative?
              return self unless index.between?(0, n_pages - 1)

              entry = @tabs.fetch(index)
              remaining = @tabs.reject { |item| item.equal?(entry) }
              publish_tabs(remaining)
              @tabs = remaining
              @children.delete(entry[:page])
              entry[:page].send(:parent=, nil)
              release_header(entry)
            end
            self
          end

          def remove(child)
            index = @children.index(child)
            session.refuse(self, :remove) unless index
            remove_page(index)
          end

          # Window teardown includes header widgets even though children lists pages only.
          def mark_destroyed
            return if destroyed?

            entries = @tabs.dup
            super
            entries.each do |entry|
              release_header(entry)
              entry[:widget].mark_destroyed
            end
          end

          protected

          def component_type = :tabs
          def input_property = :selected
          def builtin_events = %i[select tab_pointer]

          # Core validates stable header identity before dispatch; recheck under
          # the owner monitor because a queued callback may outlive its tab.
          def bind_event(event)
            return super unless event == :tab_pointer

            session.port.bind(@handle, event, proc do |context|
              session.callback(context, widget: self) do
                entry = @tabs.find { |item| item[:key] == context.payload[:tab] }
                next unless entry && !entry[:widget].destroyed? && entry[:widget].is_sensitive? && is_sensitive?

                widget = entry[:widget]
                pointer = PointerEvent.new(**context.payload.except(:tab))
                session.with_pointer(widget, pointer) do
                  widget.instance_variable_get(:@signals).fetch(:pointer_press, []).dup.each do |_name, handler|
                    break if handler.call(widget, pointer) == true
                  end
                end
              end
            end)
          end

          def forget_child(child)
            entry = @tabs.find { |item| item[:page].equal?(child) || item[:widget].equal?(child) }
            entry ? remove_page(@tabs.index(entry)) : super
          end

          private

          # Refreshes only headers; label writes never materialize a second surface.
          def refresh_headers
            return if destroyed?

            publish_tabs(@tabs)
          end

          def retire_header(widget)
            entry = @tabs.find { |item| item[:widget].equal?(widget) || item[:label].equal?(widget) }
            remove_page(@tabs.index(entry)) if entry
          end

          def header_will_change(widget, property, value)
            return unless property == :content

            names = @tabs.map { |entry| entry[:label].equal?(widget) ? value : entry[:label].text }
            valid = value.is_a?(String) && value.valid_encoding? && value.length <= Lich::WebUI::Contract::BOUNDS[:short_text] && names.uniq.length == names.length
            session.refuse(self, :tab_label) unless valid
          end

          def header_snapshot(entries)
            names = entries.map { |entry| entry[:label].text }
            session.refuse(self, :tab_label) unless names.uniq.length == names.length
            headers = entries.map do |entry|
              props = entry[:label].send(:component_props)
              { key: entry[:key], pointer_events: entry[:widget].instance_variable_get(:@props)[:pointer_events] == true,
                foreground: props[:foreground], disabled: !entry[:widget].is_sensitive? }.compact
            end
            [names, headers]
          end

          def publish_tabs(entries)
            names, headers = header_snapshot(entries)
            old_key = @props.dig(:headers, @props[:selected] || 0, :key)
            selected = headers.index { |header| header[:key] == old_key } if old_key
            selected ||= (@props[:selected] || 0).clamp(0, [names.length - 1, 0].max)
            candidate = @props.merge(names: names, headers: headers, selected: selected)
            Lich::WebUI::Validator.new.validate_component!(:tabs, candidate, owner: self.class.name, page_id: 'notebook', cid: 'tabs')
            if @handle
              session.port.layout_tabs(@handle, children: entries.map { |entry| entry[:page].materialize }, names: names, headers: headers)
            end
            @props.merge!(names: names, headers: headers, selected: selected)
          end

          def release_header(entry)
            [entry[:widget], entry[:label]].uniq.each { |widget| widget.remove_instance_variable(:@tab_owner) if widget.instance_variable_defined?(:@tab_owner) }
            entry[:widget].send(:parent=, nil)
          end
        end

        class Label < Widget
          # Retains explicit font choices as the baseline beneath temporary markup fonts.
          # @return [Label] self
          def override_font(font)
            session.synchronize do
              super
              @explicit_font_emphasis = font.weight == :bold ? :strong : :normal
              @markup_font_baseline&.each_key do |property|
                next unless font.properties.key?(property)

                @markup_font_baseline[property] = @props.fetch(property, Lich::WebUI::Adapter::UNSET)
              end
            end
            self
          end

          # A linked label's existing anchor supplies its keyboard focus target.
          # Plain focusable labels still require an unsupported interaction model.
          def can_focus=(value)
            super unless @link_markup && value == true
          end
          alias set_can_focus can_focus=

          # Creates centered, nonwrapping literal text with GTK-compatible empty defaults.
          def initialize(text = '')
            super()
            @props.merge!(content: text.to_s, align: :center, wrap: false)
          end

          # Reads the retained literal label content.
          # @return [String]
          def text = read(:content)

          # A literal, unwrapped single line uses browser font metrics. Native
          # Pango paragraph markers and multiline single-line-mode are outside
          # this bridge; refuse them instead of dropping or replacing text.
          # @param value [Boolean] single-line metric request
          # @return [Label] self
          def set_single_line_mode(value)
            session.refuse(self, :single_line_mode=) unless [true, false].include?(value)
            session.refuse(self, :single_line_mode=) if value && (@link_markup || @props[:wrap] || read(:content).match?(/[\r\n]|\p{Zl}|\p{Zp}/))
            @single_line_mode = value
            session.degrade(:single_line_metrics, 'single-line labels use browser font metrics') if value
            self
          end
          alias single_line_mode= set_single_line_mode

          # Writes literal label content through the shared text control.
          # @return [Label] self
          def text=(value)
            if @use_markup
              set_markup(String(value))
            else
              write(:content, String(value))
            end
          end
          alias set_text text=
          alias label= text=
          alias label text

          # Maps unit-interval fractions to start/center/end content alignment.
          # Independent setters preserve the other axis regardless of XML order.
          # @return [Label] self
          def set_alignment(horizontal, vertical)
            session.refuse(self, :set_alignment) unless [horizontal, vertical].all? { |value| value.is_a?(Numeric) && value.between?(0, 1) }
            self.xalign = horizontal
            self.yalign = vertical
            self
          end

          # @param value [Numeric] horizontal content alignment, 0..1
          def xalign=(value)
            session.refuse(self, :xalign=) unless value.is_a?(Numeric) && value.between?(0, 1)
            write(:align, value.zero? ? :start : (value == 1 ? :end : :center))
          end
          alias set_xalign xalign=

          # @param value [Numeric] vertical content alignment, 0..1
          def yalign=(value)
            session.refuse(self, :yalign=) unless !@link_markup && value.is_a?(Numeric) && value.between?(0, 1)
            write(:content_vertical_align, value.zero? ? :start : (value == 1 ? :end : :center))
          end
          alias set_yalign yalign=

          # Quarter-turns retain literal text and participate in natural sizing.
          # Arbitrary angles and linked Markdown labels remain unsupported.
          # @param value [Numeric] counterclockwise degrees: 0, 90, 180 or 270
          def angle=(value)
            session.refuse(self, :angle=) unless !@link_markup && [0, 90, 180, 270].include?(value)
            write(:rotation, value.to_i.to_s)
          end
          alias set_angle angle=

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
            session.refuse(self, :set_markup) unless value.is_a?(String)
            value = value.dup.force_encoding(Encoding::UTF_8)
            session.refuse(self, :set_markup) unless value.valid_encoding? && value.length <= Lich::WebUI::Contract::BOUNDS[:display_text]
            return set_link_markup(value) if value.include?('<a ') || @link_markup
            if (italic = value.match(/\A<i>([^<>]*)<\/i>\z/m))
              text = italic[1].dup.force_encoding(Encoding::UTF_8)
              session.refuse(self, :set_markup) unless text.valid_encoding?
              replace_markup_font({})
              write(:font_style, :italic)
              return write(:content, CGI.unescapeHTML(text))
            end
            if value.include?('<i>') || value.include?('<small>') || value.match?(/<span\b[^>]*\bforeground=/) || value.match?(/<span\b[^>]*\bsize=['"][a-z-]+['"]/)
              return set_styled_markup(value)
            end
            if (sized_span = value.match(/\A<span size=(['"])([0-9]{1,6})\1>([^<>]*)<\/span>\z/m))
              points = sized_span[2].to_i / 1024.0
              session.refuse(self, :set_markup) unless points.between?(6, 96)
              text = sized_span[3].dup.force_encoding(Encoding::UTF_8)
              session.refuse(self, :set_markup) unless text.valid_encoding?
              replace_markup_font(font_size: points, font_unit: :pt)
              write(:font_style, :normal)
              return write(:content, CGI.unescapeHTML(text))
            end
            if (monospace = value.match(/\A<tt>([^<>]*)<\/tt>\z/m))
              replace_markup_font(font_family: 'monospace')
              write(:font_style, :normal)
              return write(:content, CGI.unescapeHTML(monospace[1]))
            end
            if (font_span = value.match(/\A\s*<span font_family="(monospace|sans-serif|serif)">([^<>]*)<\/span>\s*\z/m))
              replace_markup_font(font_family: font_span[1])
              write(:font_style, :normal)
              return write(:content, CGI.unescapeHTML(font_span[2]))
            end
            # Boon's measured blue bold tip maps to literal text and the native
            # bounded color record. Source markup never reaches the browser.
            if (tip = value.match(/\A<span color="blue" weight="bold">([^<>]*)<\/span>\z/m))
              replace_markup_font(foreground: Color.parse('blue'))
              write(:emphasis, :strong)
              write(:font_style, :normal)
              return write(:content, CGI.unescapeHTML(tip[1]))
            end
            # Other measured headings use only b/big wrappers. Unknown markup
            # fails at its source call rather than reaching the browser.
            tags = value.scan(/<[^>]*>/)
            # armor's charts use literal spans with colour and font metadata.
            # Preserve every character; never pass markup or CSS to the client.
            span = /\A<span(?: (?:color=(?:'[^'<>]*'|"[^"<>]*")|font_desc=(?:'[^'<>]*'|"[^"<>]*")))+>\z/
            session.refuse(self, :set_markup) if tags.any? { |tag| !%w[<b> <big> </b> </big> </span>].include?(tag) && !span.match?(tag) }
            replace_markup_font({})
            session.degrade(:markup_style, 'chart colours and font faces follow browser theme; chart text is retained') if tags.any? { |tag| tag.start_with?('<span') }
            write(:emphasis, value.include?('<b>') ? :strong : (@explicit_font_emphasis || :normal))
            write(:font_style, :normal)
            write(:content, CGI.unescapeHTML(value.gsub(/<[^>]*>/, '')))
          end
          alias markup= set_markup

          # Preserves mixed emphasis, italic and foreground spans using typed fragments.
          # Parsing completes before any live or shadow label state changes.
          def set_styled_markup(value)
            fragments = LabelMarkup.new(self).parse(value)
            content = fragments.map { |fragment| fragment[:content] }.join
            session.refuse(self, :set_markup) if @props[:ellipsize] == :middle
            session.refuse(self, :single_line_mode) if @single_line_mode && content.match?(/[\r\n]|\p{Zl}|\p{Zp}/)
            session.synchronize do
              replace_markup_font({})
              write(:font_style, :normal)
              write(:content, content)
              write(:fragments, fragments)
            end
            self
          end
          private :set_styled_markup

          # Builder markup uses the same bounded formatter as direct Label calls.
          # @param value [Boolean] enable markup before materialization
          def use_markup=(value)
            session.refuse(self, :use_markup=) unless [true, false].include?(value) && !@handle && (value || !@link_markup)
            @use_markup = value
            set_markup(read(:content)) if value
          end
          alias set_use_markup use_markup=

          # Only literal text and HTTP(S) anchors with optional literal titles become typed Markdown.
          # Unsupported markup is refused, never passed to innerHTML or stripped.
          def set_link_markup(value)
            session.refuse(self, :set_markup) if @single_line_mode || @props.keys.intersect?(%i[rotation padding_x padding_y content_vertical_align line_justify max_width_chars ellipsize])
            session.refuse(self, :set_markup) if @handle && !@link_markup
            document = REXML::Document.new("<label>#{value}</label>")
            content = document.root.children.map do |part|
              if part.is_a?(REXML::Text)
                text = part.value
                session.refuse(self, :set_markup) if text.match?(/[\[\]]/)
                text
              elsif part.is_a?(REXML::Element)
                valid = part.name == 'a' && part.attributes.key?('href') && (part.attributes.keys - %w[href title]).empty? && part.children.all? { |child| child.is_a?(REXML::Text) }
                session.refuse(self, :set_markup) unless valid
                href, label = part.attributes['href'], part.texts.map(&:value).join
                uri = URI.parse(href)
                valid = %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !href.match?(/[\s<>]/) && !label.match?(/[\[\]]/)
                session.refuse(self, :set_markup) unless valid
                title = part.attributes['title']
                suffix = title ? ' "' + title.gsub(/["\\]/) { |character| "\\#{character}" } + '"' : ''
                "[#{label}](#{href.gsub('(', '%28').gsub(')', '%29')}#{suffix})"
              else
                session.refuse(self, :set_markup)
              end
            end.join
            @link_markup = true
            write(:content, content)
          rescue REXML::ParseException, URI::InvalidURIError
            session.refuse(self, :set_markup)
          end

          # Sets the shared text wrapping property.
          # @return [Label] self
          def set_wrap(value) = write(:wrap, value)
          alias wrap= set_wrap
          alias set_line_wrap set_wrap
          alias line_wrap= set_wrap

          # Maps the supported Pango word/none wrapping modes to typed text wrap.
          # @return [Label] self
          def set_wrap_mode(value)
            session.refuse(self, :wrap_mode=) unless %i[word none].include?(value)
            set_wrap(value == :word)
          end
          alias wrap_mode= set_wrap_mode
          alias set_line_wrap_mode set_wrap_mode
          alias line_wrap_mode= set_wrap_mode

          # Bounds visible wrapped lines; -1 retains the full label text.
          # @param value [Integer] -1 or 1..1024 visible lines
          # @return [Label] self
          def lines=(value)
            session.refuse(self, :lines=) unless value.is_a?(Integer) && (value == -1 || value.between?(1, 1024))
            write(:line_limit, value)
          end
          alias set_lines lines=

          # Justifies lines inside the label's text block, independently of
          # widget placement and xalign. A single line does not move the label.
          # Full justification and linked Markdown labels remain unsupported.
          # @param value [Symbol] :left, :center or :right
          def justify=(value)
            session.refuse(self, :justify=) unless !@link_markup && %i[left center right].include?(value)
            write(:line_justify, value)
          end
          alias set_justify justify=

          # Text padding belongs inside the label and never overwrites margins.
          # @param x [Integer] left/right inset, 0..64
          # @param y [Integer] top/bottom inset, 0..64
          # @return [Label] self
          def set_padding(x, y)
            session.refuse(self, :set_padding) unless [x, y].all? { |value| value.is_a?(Integer) && value.between?(0, 64) }
            self.xpad = x
            self.ypad = y
            self
          end

          # @param value [Integer] horizontal padding, 0..64
          def xpad=(value)
            session.refuse(self, :xpad=) unless !@link_markup && value.is_a?(Integer) && value.between?(0, 64)
            write(:padding_x, value)
          end

          # @param value [Integer] vertical padding, 0..64
          def ypad=(value)
            session.refuse(self, :ypad=) unless !@link_markup && value.is_a?(Integer) && value.between?(0, 64)
            write(:padding_y, value)
          end

          # Requests a minimum character width using the existing browser-font metric.
          # Packing may still allocate a larger width. Resetting a published property
          # requires a separate contract operation and is not accepted here.
          # @param count [Integer] 1..1024
          # @return [Label] self
          def set_width_chars(count)
            session.refuse(self, :set_width_chars) unless count.is_a?(Integer) && count.between?(1, 1024)
            write(:min_width_chars, count)
          end
          alias width_chars= set_width_chars

          # Caps natural label width using the core's existing character metric.
          # @param count [Integer] 1..1024; reset requests remain unsupported
          def set_max_width_chars(count)
            session.refuse(self, :set_max_width_chars) unless !@link_markup && count.is_a?(Integer) && count.between?(1, 1024)
            write(:max_width_chars, count)
          end
          alias max_width_chars= set_max_width_chars

          # End ellipsis preserves full literal content for accessibility and reads.
          # @param mode [Symbol] only :end is accepted by this label facade
          def set_ellipsize(mode)
            session.refuse(self, :set_ellipsize) unless !@link_markup && mode == :end
            write(:ellipsize, mode)
          end
          alias ellipsize= set_ellipsize

          protected

          # Applies a typed foreground cue, restoring authored/default color when
          # the matching class or provider disappears. Literal content is unchanged.
          def apply_label_color(color)
            return if @link_markup
            before = @label_color || @props[:foreground]
            after = color || @props[:foreground]
            if @handle && !destroyed? && before != after
              session.port.set(@handle, :foreground, after || Lich::WebUI::Adapter::UNSET)
            end
            @label_color = color
          end

          def component_type = @link_markup ? :markdown : :text

          # Restores only properties owned by the previous markup, then applies
          # the next bounded font span. Explicit overrides remain the baseline.
          # @param properties [Hash] validated font properties for this markup
          # @return [void]
          def replace_markup_font(properties)
            session.synchronize do
              write(:emphasis, @explicit_font_emphasis || :normal)
              (@markup_font_baseline || {}).each do |property, baseline|
                if baseline.equal?(Lich::WebUI::Adapter::UNSET)
                  if @handle && !destroyed?
                    session.with_widget(self) { session.port.set(@handle, property, baseline) }
                  end
                  @props.delete(property)
                else
                  write(property, baseline)
                end
              end
              @markup_font_baseline = {}
              properties.each do |property, value|
                @markup_font_baseline[property] = @props.fetch(property, Lich::WebUI::Adapter::UNSET)
                write(property, value)
              end
            end
          end
          private :replace_markup_font

          # Preserve the declared single-line boundary on later text/markup writes.
          def write(property, value)
            if @single_line_mode && ((property == :content && value.match?(/[\r\n]|\p{Zl}|\p{Zp}/)) || (property == :wrap && value))
              session.refuse(self, :single_line_mode)
            end
            session.synchronize do
              result = super
              if property == :content && @props.key?(:fragments)
                session.with_widget(self) { session.port.set(@handle, :fragments, Lich::WebUI::Adapter::UNSET) } if @handle && !destroyed?
                @props.delete(:fragments)
              end
              result
            end
          end

          def component_props
            props = super
            props = props.merge(foreground: @label_color) if @label_color
            @link_markup ? props.slice(:content, :key, :hidden, :disabled, :align, :margin, :width) : props
          end
        end

        # Uses the existing literal HTTP(S) anchor projection with real sensitivity.
        class LinkButton < Label
          attr_reader :uri

          # @param uri [String] destination accepted by the existing label-link policy
          # @param label [String] literal link caption
          def initialize(uri, label = uri)
            super('')
            replace_link(uri, label)
          end

          # URI and caption update together; invalid replacements leave both unchanged.
          def uri=(value)
            replace_link(value, @link_label)
          end
          alias set_uri uri=

          def label = @link_label

          # @param value [String] literal caption, subject to the label-link bounds
          def label=(value)
            replace_link(@uri, value)
          end
          alias set_label label=

          private

          def replace_link(uri, label)
            valid = [uri, label].all? { |value| value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? }
            session.refuse(self, :link) unless valid
            session.synchronize do
              set_markup("<a href=\"#{CGI.escapeHTML(uri)}\">#{CGI.escapeHTML(label)}</a>")
              @uri, @link_label = uri.dup.freeze, label.dup.freeze
            end
            self
          end
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

          # GTK emits changed for an actual programmatic text change as well as
          # typing, including read-only entries. Notify through the same handler
          # path after the validated write; equal writes must not recurse.
          # @return [Entry] self
          def set_text(value)
            text = String(value)
            text = text[0, @props[:max_length]] if @props[:max_length]
            session.synchronize do
              previous = read(:value)
              write(:value, text)
              emit_handlers(:change) unless previous == text
            end
            self
          end
          alias text= set_text

          # GTK truncates existing and programmatically assigned text to its
          # declared character limit. Configure before publication; live limit
          # changes would need an atomic limit/value update for every viewer.
          # Zero retains the core's existing 8192-character safety boundary.
          # @param value [Integer] 0..8192; zero means no smaller script limit
          # @return [Entry] self
          def set_max_length(value)
            session.refuse(self, :max_length=) unless !@handle && value.is_a?(Integer) && value.between?(0, 8192)
            @props[:max_length] = value.zero? ? 8192 : value
            self.text = read(:value)
            self
          end
          alias max_length= set_max_length

          # Sets literal placeholder text for the shared input control.
          # @return [Entry] self
          def placeholder_text=(value)
            write(:placeholder, String(value))
          end
          alias set_placeholder_text placeholder_text=

          # Uses the same typed character minimum as native WebUI forms, not a pixel guess.
          # @param count [Integer] 1..1024; reset requests remain unsupported
          # @return [Entry] self
          def set_width_chars(count)
            session.refuse(self, :set_width_chars) unless count.is_a?(Integer) && count.between?(1, 1024)
            write(:min_width_chars, count)
          end

          alias width_chars= set_width_chars

          # Caps the entry's natural character width through the existing core
          # metric. This is presentation sizing, not a limit on entered text.
          # @param count [Integer] 1..1024; reset requests remain unsupported
          def set_max_width_chars(count)
            session.refuse(self, :set_max_width_chars) unless count.is_a?(Integer) && count.between?(1, 1024)
            write(:max_width_chars, count)
          end
          alias max_width_chars= set_max_width_chars

          # Maps a unit-interval fraction to start/center/end text alignment.
          # @raise [UnsupportedOperation] for out-of-range values
          def xalign=(value)
            session.refuse(self, :xalign=) unless value.is_a?(Numeric) && value.real? && value.finite? && value.between?(0, 1)
            write(:align, value.zero? ? :start : (value == 1 ? :end : :center))
          end
          alias set_alignment xalign=

          # Sets server-owned read-only input behavior before a handle is allocated.
          # @raise [UnsupportedOperation] after materialization
          def editable=(value)
            session.refuse(self, :editable=) if @handle
            @editable = !!value
          end
          alias set_editable editable=

          # Controls the entry's visible border without affecting editability or focus.
          # @param value [Boolean] whether to draw the standard entry frame
          # @return [Entry] self
          def set_has_frame(value) = write(:has_frame, value)
          alias has_frame= set_has_frame

          protected

          def component_type = :text_input
          def input_property = :value
          def signal_map = { 'changed' => :change, 'activate' => :submit, 'focus-in-event' => :focus }

          def component_props
            super.merge(change_mode: :input, read_only: !@editable)
          end
        end

        # A button-shaped boolean input shares the ordinary checkbox state contract.
        class ToggleButton < Widget
          # Creates an unpressed button with literal text; keyword labels are supported.
          # @param text [String] positional label
          # @param label [String] keyword label, overriding text
          def initialize(text = '', label: text)
            super()
            session.refuse(self, :new) unless label.is_a?(String)
            @props.merge!(label: label, checked: false)
          end

          # Reads current callback selection or retained checkbox state.
          # @return [Boolean]
          def active? = read(:checked)
          alias active active?

          # Reads or replaces the literal control label.
          # @return [String] label text
          def label = read(:label)

          # @param value [String] literal label text
          # @return [ToggleButton] self
          def label=(value)
            write(:label, String(value))
          end

          alias set_label label=

          # Coerces legacy truthiness to the shared boolean checked property.
          # @return [ToggleButton] self
          def set_active(value)
            changed = active? != !!value
            write(:checked, !!value)
            emit_handlers(:change, signal: 'toggled') if changed
            self
          end
          alias active= set_active

          protected

          def component_type = :toggle
          def component_props = super.merge(appearance: :button)
          def input_property = :checked
          def signal_map = { 'toggled' => :change, 'clicked' => :change }
        end

        # Immediate boolean switch; active notifications observe the new value.
        class Switch < ToggleButton
          ActiveProperty = Data.define(:name)
          ACTIVE_PROPERTY = ActiveProperty.new('active').freeze

          def initialize
            super('')
          end

          def set_active(value)
            session.style_operation(self, :active=) do
              session.refuse(self, :active=) if destroyed? || ![true, false].include?(value)
              changed = active? != value
              write(:checked, value)
              emit_handlers(:change) if changed
            end
            self
          end
          alias active= set_active

          protected

          def component_props = super.merge(appearance: :switch)
          def signal_map = { 'notify::active' => :change }

          def emit_handlers(event, signal: nil)
            return super unless event == :change

            # Active is an immediate property notification, rather than a deferred form draft.
            @committed[:checked] = read(:checked)
            @signals.fetch(event, []).dup.each { |_name, handler| handler.call(self, ACTIVE_PROPERTY) }
            nil
          end
        end

        # Checkbox presentation shares the toggle value and programmatic signal semantics.
        class CheckButton < ToggleButton
          # With no supplied image GTK has nothing to reveal. Retain this hint
          # explicitly; image-bearing check buttons remain unsupported.
          # @param value [Boolean] whether an available image should be shown
          # @return [CheckButton] self
          def set_always_show_image(value)
            session.refuse(self, :always_show_image=) unless [true, false].include?(value) && children.empty?
            session.degrade(:checkbox_image_hint, 'always-show-image has no effect on an image-free checkbox') if value
            self
          end
          alias always_show_image= set_always_show_image

          # Ordinary checkboxes already show a separate indicator. Button-style mode
          # must be implemented deliberately rather than silently losing this request.
          # @param value [Boolean] only true is supported
          # @return [void]
          def draw_indicator=(value)
            session.refuse(self, :draw_indicator=) unless value == true
          end
          alias set_mode draw_indicator=

          # Space toggles a checkbox; it does not receive the focused default action.
          # GTK default-activation routing has no checkbox equivalent in the
          # browser. Accept the hint explicitly, retaining normal Space/click
          # activation and reporting the ignored true request once per session.
          # @param value [Boolean] either value is accepted; true is ignored and reported
          # @return [void]
          def receives_default=(value)
            session.refuse(self, :receives_default=) unless [true, false].include?(value)
            session.degrade(:checkbox_default, 'checkbox receives-default is ignored; activation uses Space or click') if value
          end
          alias set_receives_default receives_default=

          protected

          def component_type = :checkbox
          def component_props = @props.dup
        end

        class Button < Widget
          # Only the measured borderless request is accepted; the browser keeps its theme.
          # @param value [Symbol] :none
          def set_relief(value)
            session.refuse(self, :relief=) unless value == :none
            session.degrade(:button_relief, 'native button relief is omitted; the browser button retains its theme')
            self
          end
          alias relief= set_relief

          # Copies a bounded direction caption into this button, not another browser control.
          # File images and generic image children remain unsupported by this facade.
          # @param value [Image] same-owner Up/Down symbolic descriptor
          def set_image(value)
            session.synchronize do
              valid = value.instance_of?(Image) && value.session.equal?(session) && !value.destroyed? && !value.parent &&
                      value.directional_caption && children.empty? && (label.empty? || @button_image)
              session.refuse(self, :image=) unless valid
              self.label = value.directional_caption
              @button_image = value
            end
            self
          end
          alias image= set_image

          def image = @button_image

          # Retains a single plain Label as real typed content, including live updates.
          # @return [Button] self
          # @raise [UnsupportedOperation] for other child types or occupied/retired buttons
          def add(child)
            session.synchronize do
              valid = !destroyed? && @children.empty? && child.is_a?(Label) &&
                      !child.destroyed? && child.send(:component_type) == :text
              session.refuse(self, :add) unless valid
              super
            end
          end

          # Serializes child removal with single-child admission.
          # @return [Button] self
          def remove(child)
            session.synchronize { super }
          end

          # GTK requests are minima. Keep action text free to grow with the
          # browser font and padding instead of clipping it to a fixed box.
          def set_width_request(value)
            write(:min_width, Integer(value))
          end
          alias width_request= set_width_request

          def set_height_request(value)
            write(:min_height, Integer(value))
          end
          alias height_request= set_height_request

          # The native button receives Enter when focused, without becoming a page-wide
          # default action. Other default-routing requests remain unsupported.
          # @param value [Boolean] only true is supported
          # @return [void]
          def receives_default=(value)
            session.refuse(self, :receives_default=) unless value == true
          end
          alias set_receives_default receives_default=
          # Creates a literal action label, removing mnemonic underscores when requested.
          # Stock-button IDs are unsupported; no native GTK stock catalog is loaded.
          def initialize(text = nil, label: text, use_underline: true, stock_id: nil)
            super()
            label = '' if label.nil?
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
          alias set_label label=

          protected

          def component_type = :button
          def signal_map = { 'clicked' => :activate }
        end

        # Individually placed radio members share a same-owner group and real radio inputs.
        class RadioButton < CheckButton
          # Accepts a label, a member/group plus label, or keyword member/label.
          # The first member starts active; joining members start inactive.
          # @raise [UnsupportedOperation] for foreign or invalid groups
          def initialize(group_or_label = nil, text = '', member: nil, label: nil)
            leader = member.nil? ? (group_or_label unless group_or_label.is_a?(String)) : member
            if leader.is_a?(Array)
              Gtk.session.refuse(self, :new) unless leader.all? { |peer| peer.is_a?(RadioButton) && peer.group.include?(leader.first) }
              leader = leader.first
            end
            super(label.nil? ? (group_or_label.is_a?(String) ? group_or_label : text) : label)
            valid_group = leader.nil? || (leader.is_a?(RadioButton) && leader.session.equal?(session) && !leader.destroyed?)
            session.refuse(self, :new) unless valid_group
            @group = leader ? leader.instance_variable_get(:@group) : []
            @props[:checked] = @group.empty?
            @props[:group] = leader ? leader.send(:read, :group) : "radio-#{object_id}"
            @group << self
          end

          # Returns a snapshot suitable for the legacy group constructor.
          # @return [Array<RadioButton>]
          def group = @group.dup

          # Retires group membership before destroyed controls can be selected again.
          # @return [void]
          def mark_destroyed
            @group.delete(self)
            super
          end

          # A shared radio group must occupy one page; linked windows are unsupported.
          # @return [Lich::WebUI::Adapter::Handle] opaque control handle
          def materialize
            session.refuse(self, :group) if @group.any? { |peer| !peer.equal?(self) && peer.parent && !peer.toplevel.equal?(toplevel) }
            super
          end

          # Changes all affected member values before emitting ordered toggled signals.
          # @param value [Object] legacy truthiness; true selects this member exclusively
          # @return [RadioButton] self
          def set_active(value)
            # GTK radio deactivation preserves the selection and emits no toggled signal.
            # Select another member with true to switch the group instead.
            return self unless value

            session.synchronize do
              changes = @group.filter_map do |peer|
                desired = peer.equal?(self) ? !!value : (value ? false : peer.active?)
                [peer, desired] if peer.active? != desired
              end
              changes.sort_by! { |_peer, desired| desired ? 1 : 0 }
              changes.each { |peer, desired| peer.send(:write, :checked, desired) }
              changes.each { |peer, _desired| peer.send(:emit_handlers, :change, signal: 'toggled') }
            end
            self
          end
          alias active= set_active

          protected

          def component_type = :radio_option
          def signal_map = { 'toggled' => :change }
        end
      end
    end
  end
end
