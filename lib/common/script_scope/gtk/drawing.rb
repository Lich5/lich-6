# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # A closed, owner-bound rectangle recorder. It is valid for one draw only.
        class RectangleDrawing < ModelObject
          def initialize
            super
            @active, @commands, @paths, @layers = true, 0, [], []
            @color, @line_width = { r: 0, g: 0, b: 0, a: 1.0 }, 2
          end

          def set_source_rgb(red, green, blue)
            operation(:set_source_rgb) do
              values = [red, green, blue]
              session.refuse(self, :set_source_rgb) unless values.all? { |value| finite?(value) && value.between?(0, 1) }
              @color = %i[r g b].zip(values.map { |value| (value * 255).round }).to_h.merge(a: 1.0)
            end
          end

          def rectangle(x, y, width, height)
            operation(:rectangle) do
              valid = [x, y, width, height].all? { |value| finite?(value) && value.abs <= 65_536 }
              session.refuse(self, :rectangle) unless valid && width >= 0 && height >= 0
              @paths << { x: x, y: y, w: width, h: height }
            end
          end

          def set_line_width(value)
            operation(:set_line_width) do
              session.refuse(self, :set_line_width) unless finite?(value) && value.between?(1, 16)
              @line_width = value
            end
          end

          def fill = paint(:fill)
          def stroke = paint(:stroke)

          # Retires the borrowed context even when an original handler raises.
          def close
            @active = false
            @layers
          end
          private :close

          private

          def finite?(value) = value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

          def operation(name)
            session.style_operation(self, name) do
              @commands += 1
              session.refuse(self, name) unless @active && @commands <= 512
              yield
            end
            self
          end

          def paint(mode)
            operation(mode) do
              session.refuse(self, mode) if @layers.size + @paths.size > 512
              @layers.concat(@paths.map { |path| path.merge(kind: :rectangle, mode: mode, color: @color.dup, line_width: @line_width) })
              @paths.clear
            end
          end
        end

        # Requested-size rectangle surface; arbitrary Cairo operations remain refused.
        class DrawingArea < Widget
          def initialize
            super
            @props.merge!(width: 1, height: 1, layers: [], clip_layers: true)
          end

          def set_size_request(width, height)
            session.style_operation(self, :set_size_request) do
              valid = [width, height].all? { |value| value.is_a?(Integer) && (value == -1 || value.between?(1, 65_536)) }
              session.refuse(self, :set_size_request) if destroyed? || !valid
              super
              queue_draw if @handle
            end
            self
          end

          def allocated_width = drawing_dimension(:width)
          def allocated_height = drawing_dimension(:height)

          # Retains ordinary handler IDs and disconnection/destruction behavior.
          def signal_connect(name, &handler)
            return super unless name.to_s == 'draw'
            session.style_operation(self, :signal_connect) do
              session.refuse(self, :signal_connect) if destroyed? || !handler
              id = Widget.send(:next_signal_id)
              callback = proc { |*args| handler.call(*args) if @signal_connections.key?(id) }
              (@signals[:draw] ||= []) << ['draw', callback]
              @signal_connections[id] = [:draw, callback]
              id
            end
          end

          def signal_handler_disconnect(id) = disconnect_signal_handler(id)

          # Rebuilds the complete layer list before replacing the published frame.
          def queue_draw
            session.style_operation(self, :queue_draw) do
              session.refuse(self, :queue_draw) if destroyed? || @drawing
              layers = drawing_layers
              write(:layers, layers)
            end
            self
          end

          protected

          def component_type = :composite
          def component_props = super.merge(layers: drawing_layers)
          def bind_event(event) = event == :draw ? nil : super

          private

          def drawing_dimension(axis)
            session.style_operation(self, axis) do
              value = @props.fetch(axis)
              session.refuse(self, axis) if destroyed? || !value.is_a?(Integer) || !value.between?(1, 65_536)
              session.degrade(:drawing_allocation, 'drawing allocation follows requested dimensions; browser layout owns final placement')
              value
            end
          end

          def drawing_layers
            session.refuse(self, :draw) if destroyed? || @drawing
            allocated_width
            allocated_height
            context = RectangleDrawing.new
            begin
              @drawing = true
              @signals.fetch(:draw, []).dup.each { |_name, handler| handler.call(self, context) }
            ensure
              @drawing = false
              layers = context.send(:close)
            end
            layers
          end
        end
      end
    end
  end
end
