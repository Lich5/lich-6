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
          attr_reader :n_rows

          def initialize(rows, columns, homogeneous = false)
            super()
            @n_rows = [Integer(rows), 1].max
            @columns = [Integer(columns), 1].max
            @props.merge!(cols: @columns, gap: 0)
            session.refuse(self, :new) unless @n_rows.positive? && @columns.between?(1, 24)
            session.degrade(:homogeneous, 'grid tracks follow browser layout') if homogeneous
          end

          def n_rows=(value)
            count = Integer(value)
            session.refuse(self, :n_rows=) if count < @n_rows
            @n_rows = count
          end

          def resize(rows, columns)
            @n_rows = [Integer(rows), 1].max
            @columns = [Integer(columns), 1].max
            write(:cols, @columns)
          end

          def row_spacings=(value)
            write(:row_gap, Integer(value))
          end

          def column_spacings=(value)
            write(:column_gap, Integer(value))
          end

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
        end

        # sellunder uses Grid coordinates expressed as origin plus extent,
        # whereas Table receives opposing cell edges. Share validated placement.
        class Grid < Table
          def initialize
            super(1, 1)
          end

          alias row_spacing= row_spacings=
          alias column_spacing= column_spacings=

          def column_homogeneous=(value)
            session.refuse(self, :column_homogeneous=) unless [true, false].include?(value)
            session.degrade(:homogeneous, 'grid tracks follow browser layout') unless value
          end

          def attach(child, left, top, width, height)
            super(child, left, left + width, top, top + height)
          end
        end

        # A viewport adds no second scroll surface; its parent owns scrolling.
        class Viewport < Widget
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
        class Adjustment
          def initialize(scroll)
            @scroll = scroll
            @measurements = {}
          end

          def observe(viewer, payload)
            old = @measurements[viewer]
            # Geometry is disposable cache, not durable form input. Bound it
            # even when a long-running display sees many fresh attachments.
            @measurements.shift if !@measurements.key?(viewer) && @measurements.length >= 64
            @measurements[viewer] = payload.dup
            @changed&.call(self) if !old || old.values_at(:upper, :page_size) != payload.values_at(:upper, :page_size)
          end

          def signal_connect(name, &block)
            @scroll.session.refuse(self, "signal:#{name}") unless name == 'changed'
            @changed = block
          end

          def upper = measurement.fetch(:upper, 0)
          def page_size = measurement.fetch(:page_size, 0)
          def value = measurement.fetch(:position, 0)

          def value=(position)
            number = Float(position)
            @scroll.session.refuse(self, :value=) unless number.finite?
            target = number.round
            @scroll.session.refuse(self, :value=) unless target.between?(0, 65_536)
            @scroll.send(:write, :scroll_position, target)
            measurement[:position] = target
          end

          private

          def measurement
            viewer = @scroll.session.with_widget(@scroll) { @scroll.session.viewer_id }
            @measurements[viewer] ||= {}
          end
        end

        class ScrolledWindow < Widget
          attr_reader :vadjustment

          def initialize
            super
            @vadjustment = Adjustment.new(self)
          end

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
