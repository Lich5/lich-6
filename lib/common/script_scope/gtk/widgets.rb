# frozen_string_literal: true

require 'cgi'
require 'rexml/document'
require 'uri'

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Marker for supported legacy containers. Iteration exposes a snapshot
        # of actual children, so recursive sensitivity changes stay script-owned.
        module Container
          def each(&block) = children.each(&block)
        end

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
            refresh_layout!
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
            refresh_layout!
            self
          end
          private :insert_child

          # Maps accepted legacy signals to core events; destroy handlers accumulate separately.
          # @return [Integer] compatibility connection count
          # @raise [UnsupportedOperation] for an unmapped signal
          def signal_connect(name, &block)
            raise ArgumentError, 'signal handler is required' unless block

            name = name.to_s.tr('-', '_')
            if name == 'destroy'
              (@destroy_handlers ||= []) << block
              return @destroy_handlers.length
            end
            event = if name == 'button_press_event'
                      session.refuse(self, "signal:#{name}") unless session.port.schema(component_type)[:events].key?(:pointer_press)
                      write(:pointer_events, true)
                      :pointer_press
                    else
                      signal_map.transform_keys { |key| key.tr('-', '_') }[name] || session.refuse(self, "signal:#{name}")
                    end
            (@signals[event] ||= []) << [name, block]
            bind_event(event) if @handle
            @signals.values.sum(&:length)
          end

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

          # Accepts the measured normal-state token while retaining browser-theme backgrounds.
          # @return [Widget] self
          # @raise [UnsupportedOperation] for other state/color objects
          def override_background_color(state, colour)
            session.refuse(self, :override_background_color) unless state == :normal && colour.is_a?(Gdk::RGBA)
            session.degrade(:background_colour, 'widget background colours follow browser theme; displayed values are retained')
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

          # Aligns the widget in its allocated grid cell or enclosing frame.
          # Content alignment (Label#yalign=) is a separate request.
          # @param value [Symbol] :fill, :start, :center or :end
          def valign=(value)
            session.refuse(self, :valign=) unless %i[fill start center end].include?(value)
            write(:vertical_align, value == :fill ? :stretch : value)
            refresh_layout!
          end
          alias set_valign valign=

          # Applies horizontal start/center/end alignment.
          # @return [Widget] self
          def halign=(value)
            session.refuse(self, :halign=) unless %i[start center end].include?(value)
            write(:align, value)
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
            session.refuse(self, :can_focus=) if expected.nil? || value != expected || (is_a?(Entry) && !@editable)
          end
          alias set_can_focus can_focus=

          alias set_margin_start set_margin_left
          alias set_margin_end set_margin_right

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
          # Native window visibility needs a host operation, not a blank page.
          # @return [Widget] self
          # @raise [UnsupportedOperation] for top-level windows
          def hide
            session.refuse(self, :hide) if is_a?(Window)
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
            return self if @destroyed

            @dialogs&.dup&.each { |dialog| session.cleanup(dialog) { dialog.destroy } }
            session.port.destroy(@handle) if @handle
            @parent&.send(:forget_child, self)
            @parent = nil
            mark_destroyed
            session.forget(self)
            self
          end

          # Marks the shadow subtree retired while preserving script-readable metadata.
          # @return [void]
          def mark_destroyed
            return if @destroyed

            @destroyed = true
            @children.dup.each(&:mark_destroyed)
            @destroy_handlers&.each { |handler| session.cleanup(self) { handler.call(self) } }
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

          # Vertical allocation is supported in grids and single-child frames.
          # Refuse other parents instead of accidentally treating a flex cross axis
          # as vertical. Builder attaches parents before this validation runs.
          def component_props
            if @props.key?(:vertical_align) && parent && !parent.is_a?(Table) && !parent.is_a?(Frame) &&
               !(parent.is_a?(Box) && !parent.vertical?)
              session.refuse(self, :valign_parent)
            end
            @props.merge(layout_props)
          end

          def layout_props = {}
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
            @children.each(&:show_all)
            show
          end

          # Publishes the window through its existing owner lifecycle.
          # @return [Window] self
          def show
            materialize
            @shown = true
            self
          end

          # @return [Boolean] whether this window has been published and remains live
          def visible? = !destroyed? && @shown == true

          protected

          def component_type = :page

          def layout_props
            props = { viewport: expands?(:vertical) }
            if !@props.key?(:size) && @props.fetch(:min_width, 0).positive? && @props.fetch(:min_height, 0).positive?
              props[:size] = [@props[:min_width], @props[:min_height]]
            end
            props
          end

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

          def component_type = @orientation == :vertical ? :stack : :grid

          # Natural tracks keep long captions from spilling into equal-width peers.
          # Expanded children share surplus width; their own alignment still applies.
          def layout_props
            return {} unless %i[stack grid].include?(component_type)
            if vertical?
              allocated = parent.is_a?(Window) || (parent.is_a?(Box) && parent.vertical?)
              { fill: !!(allocated && expands?(:vertical)) }
            else
              expanding = @children.each_index.select do |index|
                child = @children[index]
                child.expands?(:horizontal) || @packing.dig(child, :expand) == true
              end.map { |index| index + 1 }
              { cols: [@children.length, 1].max, homogeneous: false, expand_columns: expanding }
            end
          end
        end

        # Legacy horizontal constructor using the existing Box packing contract.
        class HBox < Box
          # Creates a horizontal group without requesting equal child sizes.
          # @param homogeneous [Boolean] must be false; equal sizing is unsupported
          # @param spacing [Integer] gap between children in shared layout units
          # @raise [UnsupportedOperation] when homogeneous is not false
          def initialize(homogeneous = false, spacing = 0)
            super(:horizontal, spacing)
            session.refuse(self, :new) unless homogeneous.equal?(false)
          end
        end

        # Legacy vertical constructor using the existing Box packing contract.
        class VBox < Box
          # Creates a vertical group without requesting equal child sizes.
          # @param homogeneous [Boolean] must be false; equal sizing is unsupported
          # @param spacing [Integer] gap between children in shared layout units
          # @raise [UnsupportedOperation] when homogeneous is not false
          def initialize(homogeneous = false, spacing = 0)
            super(:vertical, spacing)
            session.refuse(self, :new) unless homogeneous.equal?(false)
          end
        end

        class Alignment < Widget
          include Container

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
          include Container

          # A frame's requested width is a minimum; it must still contain its
          # child's natural requisition instead of clipping the grid decoration.
          def set_width_request(value)
            write(:min_width, Integer(value))
          end
          alias width_request= set_width_request

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

          # The shared frame already places its caption at the left edge.
          # @param value [Numeric] only zero is supported
          # @return [void]
          def label_xalign=(value)
            session.refuse(self, :label_xalign=) unless value.is_a?(Numeric) && value.zero?
          end

          # Removes the frame decoration using the existing typed border property.
          # @param value [Symbol] only :none is supported
          # @return [Frame] self
          def shadow_type=(value)
            session.refuse(self, :shadow_type=) unless value == :none
            write(:border_width, 0)
          end
          alias set_shadow_type shadow_type=

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
            if @use_markup
              set_markup(String(value))
            else
              write(:content, String(value))
            end
          end
          alias set_text text=

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

          # @param value [Numeric] vertical content alignment, 0..1
          def yalign=(value)
            session.refuse(self, :yalign=) unless !@link_markup && value.is_a?(Numeric) && value.between?(0, 1)
            write(:content_vertical_align, value.zero? ? :start : (value == 1 ? :end : :center))
          end

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
            return set_link_markup(value) if value.include?('<a ') || @link_markup
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

          # Builder markup uses the same bounded formatter as direct Label calls.
          # @param value [Boolean] enable markup before materialization
          def use_markup=(value)
            session.refuse(self, :use_markup=) unless [true, false].include?(value) && !@handle && (value || !@link_markup)
            @use_markup = value
            set_markup(read(:content)) if value
          end

          # Only literal text and HTTP(S) anchors become existing typed Markdown.
          # Unsupported markup is refused, never passed to innerHTML or stripped.
          def set_link_markup(value)
            session.refuse(self, :set_markup) if @props.keys.intersect?(%i[rotation padding_x padding_y content_vertical_align])
            session.refuse(self, :set_markup) if @handle && !@link_markup
            document = REXML::Document.new("<label>#{value}</label>")
            content = document.root.children.map do |part|
              if part.is_a?(REXML::Text)
                text = part.value
                session.refuse(self, :set_markup) if text.match?(/[\[\]]/)
                text
              elsif part.is_a?(REXML::Element)
                valid = part.name == 'a' && part.attributes.keys == ['href'] && part.children.all? { |child| child.is_a?(REXML::Text) }
                session.refuse(self, :set_markup) unless valid
                href, label = part.attributes['href'], part.texts.map(&:value).join
                uri = URI.parse(href)
                valid = %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !href.match?(/[\s<>]/) && !label.match?(/[\[\]]/)
                session.refuse(self, :set_markup) unless valid
                "[#{label}](#{href.gsub('(', '%28').gsub(')', '%29')})"
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

          protected

          def component_type = @link_markup ? :markdown : :text

          def component_props
            props = super
            @link_markup ? props.slice(:content, :key, :hidden, :align, :margin, :width) : props
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
          alias set_placeholder_text placeholder_text=

          # Uses the same typed character minimum as native WebUI forms, not a pixel guess.
          # @param count [Integer] 1..1024; reset requests remain unsupported
          # @return [Entry] self
          def set_width_chars(count)
            session.refuse(self, :set_width_chars) unless count.is_a?(Integer) && count.between?(1, 1024)
            write(:min_width_chars, count)
          end

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

        # Checkbox presentation shares the toggle value and programmatic signal semantics.
        class CheckButton < ToggleButton
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
