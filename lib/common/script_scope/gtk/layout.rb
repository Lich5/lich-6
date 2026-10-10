# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module PolicyType
          AUTOMATIC = :automatic
        end

        module AttachOptions
          EXPAND = 1
          SHRINK = 2
          FILL = 4
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
            valid &&= left >= 0 && right > left && right <= 24 && top >= 0 && bottom > top
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

        # sellunder uses Grid coordinates expressed as origin plus extent,
        # whereas Table receives opposing cell edges. Share validated placement.
        class Grid < Table
          # Creates the origin-plus-extent grid variant with one initial cell.
          def initialize
            super(1, 1)
          end

          alias row_spacing= row_spacings=
          alias column_spacing= column_spacings=
          alias set_row_spacing row_spacings=
          alias set_column_spacing column_spacings=

          # Maps the GTK equal-column request to the existing shared grid policy.
          # @raise [UnsupportedOperation] for nonboolean values
          def column_homogeneous=(value)
            session.refuse(self, :column_homogeneous=) unless [true, false].include?(value)
            write(:homogeneous, value)
          end

          # Equal row tracks are independent of equal columns and surplus-space
          # spreading. Content spanning rows contributes to their shared minimum.
          # @param value [Boolean] whether all occupied rows have equal height
          def row_homogeneous=(value)
            session.refuse(self, :row_homogeneous=) unless [true, false].include?(value)
            write(:equal_rows, value)
          end
          alias set_row_homogeneous row_homogeneous=

          # Translates zero-based origin plus width/height to Table's opposing cell edges.
          # @return [Grid] self
          def attach(child, left, top, width, height)
            super(child, left, left + width, top, top + height)
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
          def initialize(scroll)
            super()
            @scroll = scroll
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
          # Reads the cached vertical scroll position for the attributed viewer.
          # @return [Numeric] zero before measurement
          def value = measurement.fetch(:position, 0)

          # Requests a finite, rounded vertical position and updates the local measurement cache.
          # @raise [UnsupportedOperation] for positions outside the transport bounds
          def value=(position)
            number = Float(position)
            @scroll.session.refuse(self, :value=) unless number.finite?
            target = number.round
            @scroll.session.refuse(self, :value=) unless target.between?(0, 65_536)
            @scroll.send(:write, :scroll_position, target)
            measurement[:position] = target
          end
          alias set_value value=

          private

          def measurement
            viewer = @scroll.session.with_widget(@scroll) { @scroll.session.viewer_id }
            @measurements[viewer] ||= {}
          end
        end

        class ScrolledWindow < Widget
          include Container

          attr_reader :vadjustment

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

          # Creates a shared scroll control with a vertical measurement facade.
          def initialize
            super
            @vadjustment = ScrollAdjustment.new(self)
          end

          # Accepts known GTK policy tokens while reporting browser-owned overflow behavior.
          # @return [ScrolledWindow] self
          # @raise [UnsupportedOperation] for unknown policies
          def set_policy(horizontal, vertical)
            session.refuse(self, :set_policy) unless [horizontal, vertical].all? { |value| %i[automatic always never].include?(value) }
            session.degrade(:scrollbar_policy, 'browser provides scrollbars when content overflows')
            self
          end

          protected

          def component_type = :scroll
          def builtin_events = [:scrolled]

          def bind_event(event)
            return super unless event == :scrolled

            session.port.bind(@handle, :scrolled, proc do |context|
              session.callback(context, widget: self) { @vadjustment.observe(context.viewer_id, context.payload) }
            end)
          end
        end
      end
    end
  end
end
