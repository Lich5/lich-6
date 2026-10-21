# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module PolicyType
          AUTOMATIC = :automatic
          ALWAYS = :always
          NEVER = :never
        end

        module AttachOptions
          EXPAND = 1
          SHRINK = 2
          FILL = 4
        end

        EXPAND = AttachOptions::EXPAND
        FILL = AttachOptions::FILL

        # Natural-sized children at bounded pixel coordinates, with no native GTK window.
        class Fixed < Widget
          include Container

          def initialize
            super
            @props[:positioned] = true
          end

          # Adds a same-owner child at integer coordinates; failed attachment restores its placement.
          # @return [Fixed] self
          def put(child, x, y)
            session.synchronize do
              valid = !destroyed? && child.is_a?(Widget) && child.session.equal?(session) && !child.destroyed? && child.parent.nil?
              session.refuse(self, :put) unless valid
              placement = position(x, y)
              previous = child.instance_variable_get(:@placement)
              child.placement = placement
              begin
                insert_child(child, @children.length, placement: placement)
              rescue StandardError
                child.placement = previous
                raise
              end
            end
            self
          end

          # GTK's generic add places an unpositioned child at the origin.
          def add(child) = put(child, 0, 0)

          # Moves only an existing child, preserving placement on refusal.
          # @return [Fixed] self
          def move(child, x, y)
            session.synchronize do
              session.refuse(self, :move) unless !destroyed? && child.is_a?(Widget) && !child.destroyed? && child.parent.equal?(self)
              placement = position(x, y)
              session.port.place(@handle, child.materialize, placement) if @handle
              child.placement = placement
            end
            self
          end

          # Keeps attachment validation, adapter detachment and shadow removal atomic with moves.
          # @return [Fixed] self
          def remove(child)
            session.synchronize { super }
          end

          protected

          def component_type = :overlay

          private

          def position(x, y)
            session.refuse(self, :position) unless [x, y].all? { |value| value.is_a?(Integer) && Lich::WebUI::Contract::BOUNDS[:geometry].cover?(value) }
            { x: x, y: y }
          end
        end

        # Bounded Layout positioning reuses Fixed; the canvas clips offscreen children.
        # Virtual dimensions reuse the bounded overlay extent.
        class Layout < Fixed
          # @param hadjustment [nil] only browser-owned scrolling is supported
          # @param vadjustment [nil] only browser-owned scrolling is supported
          # @raise [UnsupportedOperation] for native scroll adjustments
          def initialize(hadjustment = nil, vadjustment = nil)
            super()
            session.refuse(self, :new) unless hadjustment.nil? && vadjustment.nil?
            @props[:clip_children] = true
            @props[:pointer_tracking] = true
          end

          def set_size(width, height)
            session.synchronize do
              session.refuse(self, :set_size) unless [width, height].all? { |value| value.is_a?(Numeric) && value.finite? && value.between?(0, 65_536) }
              write(:width, width.round)
              write(:height, height.round)
            end
            self
          end

          def width = read(:width) || 0
          def height = read(:height) || 0

          # Queued polling keeps the drag's originating viewer until release.
          def pointer_viewer = @pointer_press && @pointer_viewer

          # Reads the current attachment's bounded window coordinates, never OS state.
          def pointer_position
            viewer = session.with_widget(self) { session.viewer_id }
            session.refuse(self, :pointer_position) unless viewer == @pointer_viewer
            @last_pointer = session.with_widget(self) { session.port.get(@handle, :pointer_position) } || @last_pointer
            session.refuse(self, :pointer_position) unless @last_pointer && !destroyed?
            @last_pointer
          rescue Lich::WebUI::Error
            raise unless @pointer_cancelled && @last_pointer
            @last_pointer
          end

          # Detach cancels the script's drag loop using its original release handlers.
          def cancel_pointer(viewer)
            return unless @pointer_viewer == viewer && @pointer_press
            @pointer_cancelled = true
            event = @pointer_press
            @pointer_press = nil
            @signals.fetch(:pointer_release, []).dup.each { |_name, handler| handler.call(self, PointerEvent.new(**event.to_h.merge(released: true))) }
          end

          protected

          def builtin_events = [:pointer_motion]

          private

          # GTK integer coordinates accept finite numeric script calculations.
          def position(x, y)
            session.refuse(self, :position) unless [x, y].all? { |value| value.is_a?(Numeric) && value.finite? && value.between?(-65_536, 65_536) }
            super(x.to_i, y.to_i)
          end
        end

        # A single-child pointer surface uses the existing owner/viewer event bridge.
        class EventBox < Widget
          include Container

          def initialize
            super
            @props.merge!(orientation: :vertical, gap: 0)
          end

          # Preserves GtkBin's single-child rule rather than silently stacking content.
          # @return [EventBox] self
          def add(child)
            session.synchronize do
              session.refuse(self, :add) unless @children.empty?
              super
            end
          end

          protected

          def component_type = :stack

          def layout_props
            alignment = @children.first&.instance_variable_get(:@props)&.fetch(:vertical_align, nil)
            return {} unless alignment || @published_layout&.key?(:content_align)
            { content_align: alignment || :stretch }
          end
        end

        # The plain table in vars/alias contains widgets, not a TreeView model.
        # Cell positions become validated grid placements without extra handles.
        class Table < Widget
          include Container

          attr_reader :n_rows

          # Creates a widget grid using the shared natural/equal track policy.
          # @param rows [Integer] initial row count, clamped to at least one
          # @param columns [Integer] initial column count, bounded by the grid contract
          # @param homogeneous [Boolean] legacy equal-sizing request
          def initialize(rows, columns, homogeneous = false)
            super()
            @n_rows = [Integer(rows), 1].max
            @columns = [Integer(columns), 1].max
            @props.merge!(cols: @columns, gap: 0, homogeneous: homogeneous)
            session.refuse(self, :new) unless @n_rows.positive? && @columns.between?(1, 24)
            session.degrade(:homogeneous_rows, 'equal columns are retained; row heights follow browser layout') if homogeneous
          end

          def n_rows=(value)
            count = Integer(value)
            session.refuse(self, :n_rows=) if count < @n_rows
            @n_rows = count
          end

          # Updates shadow row count and the shared grid's column count.
          # @return [Table] self
          def resize(rows, columns)
            @n_rows = [Integer(rows), 1].max
            @columns = [Integer(columns), 1].max
            write(:cols, @columns)
          end

          # Maps legacy row spacing to the shared row-gap property.
          # @return [Table] self
          def row_spacings=(value)
            write(:row_gap, Integer(value))
          end

          # Maps legacy column spacing to the shared column-gap property.
          # @return [Table] self
          def column_spacings=(value)
            write(:column_gap, Integer(value))
          end

          # Converts opposing zero-based cell edges to one-based grid placement and padding.
          # The grid grows to contain the child; unsupported attach flags/coordinates are refused.
          # @return [Table] self
          def attach(child, left, right, top, bottom, xoptions = 5, yoptions = 5, xpadding = 0, ypadding = 0)
            valid = [left, right, top, bottom].all? { |value| value.is_a?(Integer) }
            valid &&= left >= 0 && right > left && right <= 24 && top >= 0 && bottom > top &&
                      bottom <= Lich::WebUI::Contract::BOUNDS[:children]
            session.refuse(self, :attach) unless valid
            session.refuse(self, :attach) unless [xoptions, yoptions].all? { |value| %i[fill expand shrink].include?(value) || (value.is_a?(Integer) && value.between?(0, 7)) }
            if right > @columns
              @columns = right
              write(:cols, @columns)
            end
            child.placement = { column: left + 1, row: top + 1, span: right - left, row_span: bottom - top }
            child.send(:write, :margin, { left: xpadding, right: xpadding, top: ypadding, bottom: ypadding })
            @n_rows = [@n_rows, bottom].max
            add(child)
          end

          # Legacy convenience spelling uses the same default expansion and padding.
          # @return [Table] self
          def attach_defaults(child, left, right, top, bottom)
            session.refuse(self, :attach_defaults) if is_a?(Grid)
            attach(child, left, right, top, bottom)
          end

          protected

          def component_type = :grid

          # A spanning expanding child can request surplus width in each covered track.
          # This reuses the native grid policy without imposing equal-sized columns.
          def layout_props
            columns = @children.select { |child| child.expands?(:horizontal) }.flat_map do |child|
              placement = child.instance_variable_get(:@placement) || {}
              first = placement.fetch(:column, 1)
              (first...(first + placement.fetch(:span, 1))).to_a
            end
            { expand_columns: columns.uniq.sort }
          end
        end

        # Nonselecting flow layout uses the existing grid ownership and bounds.
        # The browser reduces the requested column maximum to fit available width.
        class FlowBox < Table
          # Creates a nonselecting flow with a seven-column maximum and natural cell sizes.
          def initialize
            super(1, 7, false)
            @props[:flow] = true
          end

          # Accepts only :none; selectable flow children are outside this adapter.
          # @param value [Symbol] :none
          # @raise [UnsupportedOperation] for other modes or a destroyed flow
          def selection_mode=(value)
            session.style_operation(self, :selection_mode=) do
              session.refuse(self, :selection_mode=) if destroyed? || value != :none
              @selection_mode = value
            end
          end

          alias set_selection_mode selection_mode=

          # Combatical requests the natural one-child minimum; larger minima require new layout semantics.
          def set_min_children_per_line(value)
            session.style_operation(self, :set_min_children_per_line) do
              session.refuse(self, :set_min_children_per_line) if destroyed? || value != 1
            end
            self
          end

          # @return [Symbol] :none, including before any explicit assignment
          def selection_mode = @selection_mode || :none

          # @return [Integer] authored column maximum; the browser may fit fewer columns
          def max_children_per_line = read(:cols)

          # Updates both the published column maximum and shadow table dimensions.
          # @param value [Integer] maximum columns, from 1 through 24
          # @raise [UnsupportedOperation] for an invalid maximum or a destroyed flow
          def max_children_per_line=(value)
            session.style_operation(self, :max_children_per_line=) do
              session.refuse(self, :max_children_per_line=) if destroyed? || !value.is_a?(Integer) || !value.between?(1, 24)
              write(:cols, value)
              @columns = value
            end
          end
          alias set_max_children_per_line max_children_per_line=

          # Applies equal-width columns and equal-height rows together.
          # @param value [Boolean] whether flow cells share equal dimensions
          # @raise [UnsupportedOperation] for nonboolean input or a destroyed flow
          def homogeneous=(value)
            session.style_operation(self, :homogeneous=) do
              session.refuse(self, :homogeneous=) if destroyed? || ![true, false].include?(value)
              write(:homogeneous, value)
              write(:equal_rows, value)
            end
          end

          # Sets the vertical gap without changing the horizontal gap.
          # @param value [Integer] CSS pixels, from 0 through 64
          def row_spacing=(value)
            flow_spacing(:row_gap, value)
          end

          # Sets the horizontal gap used when fitting columns to available width.
          # @param value [Integer] CSS pixels, from 0 through 64
          def column_spacing=(value)
            flow_spacing(:column_gap, value)
          end
          alias set_row_spacing row_spacing=
          alias set_column_spacing column_spacing=

          # Explicit cell placement and selection are outside nonselecting flow layout.
          # @raise [UnsupportedOperation] explicit table coordinates are unsupported
          def attach(*) = session.refuse(self, :attach)
          # @raise [UnsupportedOperation] use max_children_per_line instead of fixed dimensions
          def resize(*) = session.refuse(self, :resize)

          private

          # Validates an owned spacing update before writing shared renderer properties.
          # @raise [UnsupportedOperation] outside the supported 0..64 pixel range
          def flow_spacing(property, value)
            session.style_operation(self, property) do
              session.refuse(self, property) if destroyed? || !value.is_a?(Integer) || !value.between?(0, 64)
              write(property, value)
            end
          end
        end

        # sellunder uses Grid coordinates expressed as origin plus extent,
        # whereas Table receives opposing cell edges. Share validated placement.
        class Grid < Table
          # Creates the origin-plus-extent grid variant with one initial cell.
          def initialize
            super(1, 1)
            @grid_origins = {}.compare_by_identity
          end

          alias row_spacing= row_spacings=
          alias column_spacing= column_spacings=
          alias set_row_spacing row_spacings=
          alias set_column_spacing column_spacings=

          # Finds the first attached child covering an original signed GTK cell.
          # @return [Widget, nil] covering child, or nil for an empty cell
          # @raise [UnsupportedOperation] for invalid coordinates or a retired grid
          def get_child_at(column, row)
            session.synchronize do
              valid = [column, row].all? { |value| value.is_a?(Integer) && value.abs <= 65_536 }
              session.refuse(self, :get_child_at) if destroyed? || !valid
              @grid_origins.find do |_child, (left, top, width, height)|
                column >= left && column < left + width && row >= top && row < top + height
              end&.first
            end
          end

          # Maps the GTK equal-column request to the existing shared grid policy.
          # @raise [UnsupportedOperation] for nonboolean values
          def column_homogeneous=(value)
            session.refuse(self, :column_homogeneous=) unless [true, false].include?(value)
            write(:homogeneous, value)
          end

          alias set_column_homogeneous column_homogeneous=

          # Equal row tracks are independent of equal columns and surplus-space
          # spreading. Content spanning rows contributes to their shared minimum.
          # @param value [Boolean] whether all occupied rows have equal height
          def row_homogeneous=(value)
            session.refuse(self, :row_homogeneous=) unless [true, false].include?(value)
            write(:equal_rows, value)
          end
          alias set_row_homogeneous row_homogeneous=

          # Retains signed GTK origins and maps them into positive shared grid
          # coordinates. The translation is uniform, preserving gaps and spans.
          # @return [Grid] self
          def attach(child, left, top, width, height)
            session.synchronize do
              valid = [left, top, width, height].all? { |value| value.is_a?(Integer) }
              valid &&= width.positive? && height.positive? && left.abs <= 65_536 && top.abs <= 65_536
              session.refuse(self, :attach) unless valid && !destroyed? && child.is_a?(Widget) &&
                                                   child.session.equal?(session) && !child.destroyed? && !child.parent
              ancestor = self
              while ancestor
                session.refuse(self, :attach) if ancestor.equal?(child)
                ancestor = ancestor.parent
              end
              proposed = @grid_origins.merge(child => [left, top, width, height])
              previous = { origins: @grid_origins, columns: @columns, rows: @n_rows,
                           placements: (@children + [child]).to_h { |widget| [widget, widget.instance_variable_get(:@placement)] } }
              apply_grid_origins(proposed)
              @grid_origins = proposed
              begin
                add(child)
              rescue StandardError
                restore_attachment(child, previous)
                raise
              end
            end
            self
          end

          # Rebase remaining placements after detaching while keeping handles live.
          def remove(child)
            session.synchronize do
              super
              @grid_origins.delete(child)
              apply_grid_origins(@grid_origins)
            end
            self
          end

          protected

          def forget_child(child)
            @grid_origins.delete(child)
            super
            apply_grid_origins(@grid_origins) unless destroyed?
          end

          private

          # Restore both representations, including an already inserted child and
          # detached controls whose old placement exceeds this grid's old width.
          def restore_attachment(child, previous)
            if child.parent.equal?(self)
              session.port.detach(@handle, child.materialize) if @handle
              @children.delete(child)
              child.parent = nil
            end
            @grid_origins = previous[:origins]
            previous[:placements].each { |widget, placement| widget.placement = placement }
            @columns, @n_rows = previous.values_at(:columns, :rows)
            @props[:cols] = @columns
            if @handle
              placements = previous[:placements].filter_map do |widget, placement|
                handle = widget.instance_variable_get(:@handle)
                [handle, placement || {}] if handle
              end.to_h
              child_handle = child.instance_variable_get(:@handle)
              child_placement = placements.delete(child_handle)
              expanding = layout_props.fetch(:expand_columns)
              session.port.layout_grid(@handle, columns: @columns, placements: placements, expand_columns: expanding)
              if child_handle
                # Separate the rejected child so a full grid's rollback stays
                # within the adapter's placement-map capacity.
                columns = [@columns, child_placement.fetch(:column, 1) + child_placement.fetch(:span, 1) - 1].max
                session.port.layout_grid(@handle, columns: columns, placements: { child_handle => child_placement }, expand_columns: expanding)
                session.port.layout_grid(@handle, columns: @columns, placements: {}, expand_columns: expanding) if columns != @columns
              end
            end
            session.refresh_label_styles
            refresh_layout!
          end

          def apply_grid_origins(origins)
            left = [0, *origins.values.map(&:first)].min
            top = [0, *origins.values.map { |origin| origin[1] }].min
            placements = origins.to_h do |child, (x, y, width, height)|
              [child, { column: x - left + 1, row: y - top + 1, span: width, row_span: height }]
            end
            columns = [1, *placements.values.map { |p| p[:column] + p[:span] - 1 }].max
            rows = [1, *placements.values.map { |p| p[:row] + p[:row_span] - 1 }].max
            valid = columns <= 24 && rows <= Lich::WebUI::Contract::BOUNDS[:children]
            session.refuse(self, :attach) unless valid
            expanding = placements.flat_map do |child, p|
              child.expands?(:horizontal) ? (p[:column]...(p[:column] + p[:span])).to_a : []
            end.uniq.sort
            if @handle
              handles = placements.to_h { |child, p| [child.materialize, p] }
              session.port.layout_grid(@handle, columns: columns, placements: handles, expand_columns: expanding)
            end
            placements.each { |child, p| child.placement = p }
            @columns, @n_rows = columns, rows
            @props[:cols] = columns
            refresh_layout!
          end
        end

        # A viewport adds no second scroll surface; its parent owns scrolling.
        class Viewport < Widget
          include Container

          # Creates a zero-gap wrapper without a second scroll surface or native adjustments.
          # @raise [UnsupportedOperation] when either adjustment argument is supplied
          def initialize(horizontal = nil, vertical = nil)
            super()
            session.refuse(self, :new) unless horizontal.nil? && vertical.nil?
            @props[:gap] = 0
          end

          protected

          def component_type = :stack
        end

        # Adjustment reads report the last real viewer measurements. They do
        # not invent screen geometry or poll the browser synchronously.
        class ScrollAdjustment < Adjustment
          # Creates a viewer-measurement cache for one scroll container.
          def initialize(scroll, axis = :vertical)
            super()
            @scroll = scroll
            @axis = axis
            @measurements = {}
          end

          # Caches bounded viewer measurements and signals changed extents, not mere movement.
          # @return [void]
          def observe(viewer, payload)
            old = @measurements[viewer]
            # Geometry is disposable cache, not durable form input. Bound it
            # even when a long-running display sees many fresh attachments.
            @measurements.shift if !@measurements.key?(viewer) && @measurements.length >= 64
            @measurements[viewer] = payload.dup
            @changed&.call(self) if !old || old.values_at(:upper, :page_size) != payload.values_at(:upper, :page_size)
          end

          # Registers the supported changed notification for scroll extent updates.
          # @raise [UnsupportedOperation] for other signals
          def signal_connect(name, &block)
            @scroll.session.refuse(self, "signal:#{name}") unless name.to_s.tr('-', '_') == 'changed'
            @changed = block
          end

          # Reads the last measured content extent for the attributed viewer.
          # @return [Numeric] zero before measurement
          def upper = measurement.fetch(:upper, 0)
          # Reads the last measured viewport extent for the attributed viewer.
          # @return [Numeric] zero before measurement
          def page_size = measurement.fetch(:page_size, 0)
          # Reads this axis's cached scroll position for the attributed viewer.
          # @return [Numeric] zero before measurement
          def value = measurement.fetch(:position, 0)

          # Requests a finite, rounded position and updates the local measurement cache.
          # @raise [UnsupportedOperation] for positions outside the transport bounds
          def value=(position)
            number = Float(position)
            @scroll.session.refuse(self, :value=) unless number.finite?
            target = number.round
            @scroll.session.refuse(self, :value=) unless target.between?(-65_536, 65_536)
            target = [target, 0].max
            @scroll.request_position(@axis, target)
            measurement[:position] = target
          end
          alias set_value value=

          private

          def measurement
            viewer = @scroll.session.with_widget(@scroll) { @scroll.session.viewer_id }
            @measurements[viewer] ||= {}
          end
        end

        # Single-child visibility container; slide timing remains browser-owned.
        class Revealer < Box
          def initialize
            super(:vertical, 0)
            @reveal_child, @shown = false, false
          end

          def add(child)
            session.refuse(self, :add) unless children.empty?
            super
          end

          def set_reveal_child(value)
            session.style_operation(self, :set_reveal_child) do
              session.refuse(self, :set_reveal_child) if destroyed? || ![true, false].include?(value)
              @reveal_child = value
              write(:hidden, !@shown)
            end
            self
          end
          alias reveal_child= set_reveal_child
          def reveal_child? = @reveal_child

          def set_transition_type(value)
            session.style_operation(self, :set_transition_type) do
              session.refuse(self, :set_transition_type) if destroyed? || !%i[none slide_down].include?(value)
              session.degrade(:reveal_animation, 'reveal state is immediate; native slide animation is omitted')
            end
            self
          end

          def set_transition_duration(value)
            session.style_operation(self, :set_transition_duration) do
              session.refuse(self, :set_transition_duration) if destroyed? || !value.is_a?(Integer) || !value.between?(0, 10_000)
              session.degrade(:reveal_animation, 'reveal state is immediate; native slide animation is omitted')
            end
            self
          end

          protected

          def write(property, value)
            if property == :hidden
              @shown = !value
              value ||= !@reveal_child
            end
            super
          end
        end

        class ScrolledWindow < Widget
          include Container

          attr_reader :vadjustment, :hadjustment

          # Browser viewport measurements supply the scroller's content allocation.
          def allocation
            width, height = @hadjustment.page_size, @vadjustment.page_size
            if width.zero? && height.zero? && parent.is_a?(Window)
              return parent.allocation
            end
            Window::Allocation.new(width, height)
          end

          # A shared sequence makes repeated same-position requests observable on either axis.
          def request_position(axis, target)
            unless session.with_widget(self) { session.viewer_id }
              initial = (@props[:initial_scroll] || { x: 0, y: 0 }).merge(axis == :horizontal ? { x: target } : { y: target })
              write(:initial_scroll, initial)
              return
            end
            write(axis == :horizontal ? :scroll_position_x : :scroll_position, target)
            @scroll_revision = (@scroll_revision || 0) + 1
            write(axis == :horizontal ? :scroll_revision_x : :scroll_revision, @scroll_revision)
          end

          # Explicit compatibility policy: accept :in but omit its inset decoration.
          # :none is already represented by the browser scroll container. Other shadow
          # types are refused; this is not an arbitrary style-dropping mechanism.
          # @param value [Symbol] :none or :in
          # @return [void]
          def shadow_type=(value)
            session.refuse(self, :shadow_type=) unless %i[none in].include?(value)
            session.degrade(:scroll_shadow, 'shadow-type=in accepted; inset decoration omitted; browser theme applies') if value == :in
          end
          alias set_shadow_type shadow_type=

          # Creates a browser-owned scroller; native adjustment objects are unsupported.
          # @param horizontal [nil] optional legacy horizontal adjustment argument
          # @param vertical [nil] optional legacy vertical adjustment argument
          def initialize(horizontal = nil, vertical = nil)
            super()
            session.refuse(self, :new) unless horizontal.nil? && vertical.nil?
            @vadjustment = ScrollAdjustment.new(self)
            @hadjustment = ScrollAdjustment.new(self, :horizontal)
          end

          # Retains the GTK preference; browser/host chrome owns scrollbar presentation.
          # @param value [Boolean] requested overlay scrollbar preference
          # @return [ScrolledWindow] self
          # @raise [UnsupportedOperation] for invalid values, ownership or retired widgets
          def set_overlay_scrolling(value)
            session.style_operation(self, :set_overlay_scrolling) do
              session.refuse(self, :set_overlay_scrolling) if destroyed? || ![true, false].include?(value)
              @overlay_scrolling = value
              session.degrade(:overlay_scrolling, 'overlay scrollbar preference retained; browser and host determine scrollbar presentation')
            end
            self
          end
          alias overlay_scrolling= set_overlay_scrolling

          # @return [Boolean] retained preference, GTK default true before assignment
          def overlay_scrolling?
            session.style_operation(self, :overlay_scrolling) do
              session.refuse(self, :overlay_scrolling) if destroyed?
              @overlay_scrolling.nil? ? true : @overlay_scrolling
            end
          end
          alias overlay_scrolling overlay_scrolling?

          # Requests a minimum viewport height independently of an explicit height request.
          # GTK's -1 reset becomes an unconstrained zero browser minimum.
          def set_min_content_height(value)
            session.style_operation(self, :set_min_content_height) do
              valid = value.is_a?(Integer) && value.between?(-1, Lich::WebUI::Contract::BOUNDS[:geometry].end)
              session.refuse(self, :set_min_content_height) if destroyed? || !valid
              write(:min_height, [value, 0].max)
              @min_content_height = value
            end
            self
          end
          alias min_content_height= set_min_content_height

          def min_content_height
            session.style_operation(self, :min_content_height) { @min_content_height || -1 }
          end

          # Minimum viewport width uses the same bounded floor/reset as height.
          def set_min_content_width(value)
            session.style_operation(self, :set_min_content_width) do
              valid = value.is_a?(Integer) && value.between?(-1, Lich::WebUI::Contract::BOUNDS[:geometry].end)
              session.refuse(self, :set_min_content_width) if destroyed? || !valid
              write(:min_width, [value, 0].max)
              @min_content_width = value
            end
            self
          end
          alias min_content_width= set_min_content_width

          def min_content_width
            session.style_operation(self, :min_content_width) { @min_content_width || -1 }
          end

          def hscrollbar_policy = (@scrollbar_policy || %i[automatic automatic]).first
          def vscrollbar_policy = (@scrollbar_policy || %i[automatic automatic]).last
          def set_hscrollbar_policy(value) = session.style_operation(self, :set_hscrollbar_policy) { set_policy(value, vscrollbar_policy) }
          def set_vscrollbar_policy(value) = session.style_operation(self, :set_vscrollbar_policy) { set_policy(hscrollbar_policy, value) }
          alias hscrollbar_policy= set_hscrollbar_policy
          alias vscrollbar_policy= set_vscrollbar_policy

          # Accepts known GTK policy tokens while reporting browser-owned overflow behavior.
          # @return [ScrolledWindow] self
          # @raise [UnsupportedOperation] for unknown policies
          def set_policy(horizontal, vertical)
            horizontal, vertical = [horizontal, vertical].map do |value|
              { AUTOMATIC: :automatic, ALWAYS: :always, NEVER: :never }.fetch(value, value)
            end
            session.refuse(self, :set_policy) unless [horizontal, vertical].all? { |value| %i[automatic always never].include?(value) }
            session.refuse(self, :set_policy) if destroyed?
            @scrollbar_policy = [horizontal, vertical].freeze
            session.degrade(:scrollbar_policy, 'browser provides scrollbars when content overflows')
            self
          end

          # Wraps one non-scrollable child in the existing viewport projection.
          # Existing viewports are attached directly. Failed attachment leaves the
          # caller's child alive and unparented, retaining its handle and inputs.
          # @param child [Widget] unparented, live widget belonging to this script
          # @return [ScrolledWindow] self
          # @raise [UnsupportedOperation] for invalid ownership, lifecycle or nesting
          def add_with_viewport(child)
            session.style_operation(self, :add_with_viewport) do
              valid = !destroyed? && @children.empty? && child.is_a?(Widget) &&
                      child.session.equal?(session) && !child.destroyed? && child.parent.nil?
              session.refuse(self, :add_with_viewport) unless valid
              ancestor = self
              while ancestor
                session.refuse(self, :add_with_viewport) if ancestor.equal?(child)
                ancestor = ancestor.parent
              end
              next add(child) if child.is_a?(Viewport)

              viewport = Viewport.new
              begin
                viewport.add(child)
                add(viewport)
              rescue StandardError
                viewport.remove(child) if child.parent.equal?(viewport)
                viewport.destroy
                raise
              end
            end
          end

          # A viewport requests allocation for scrolling rather than expanding
          # its host to the full content size. Explicit expansion flags still win.
          # @api private
          # @return [Boolean] allocation demand along the requested axis
          def expands?(axis)
            return super unless @children.first.is_a?(Viewport) || @children.first.is_a?(Layout)

            explicit = axis == :horizontal ? @hexpand : @vexpand
            explicit.nil? ? true : explicit
          end

          protected

          def component_type = :scroll
          def builtin_events = [:scrolled]

          def layout_props
            allocated = parent.is_a?(Window) || (parent.is_a?(Box) && parent.vertical?)
            { fill: !!(allocated && (@children.first.is_a?(Viewport) || @children.first.is_a?(Layout)) && expands?(:vertical)) }
          end

          def bind_event(event)
            return super unless event == :scrolled

            session.port.bind(@handle, :scrolled, proc do |context|
              session.callback(context, widget: self) do
                @vadjustment.observe(context.viewer_id, context.payload.slice(:position, :upper, :page_size))
                @hadjustment.observe(context.viewer_id, context.payload.slice(:position_x, :upper_x, :page_size_x).transform_keys { |key| key.to_s.delete_suffix('_x').to_sym }) if context.payload.key?(:position_x)
              end
            end)
          end
        end
      end
    end
  end
end
