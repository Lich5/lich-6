# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # A client-area title row composed from existing shared controls. It does
        # not replace native OS chrome or introduce another window lifecycle.
        class HeaderBar < Box
          def initialize
            super(:horizontal, 6)
            @start = Box.new(:horizontal, 6)
            @middle = Box.new(:vertical, 0)
            @end = Box.new(:horizontal, 6)
            @title_label = Label.new('')
            @middle.add(@title_label)
            @close_button = Button.new('Close')
            @close_button.set_tooltip_text('Close window')
            @close_button.signal_connect('clicked') do
              window = parent
              window.close if window.is_a?(Window) && window.titlebar.equal?(self)
            end
            [@start, @middle, @end, @close_button].each do |child|
              pack(child, [], expand: child.equal?(@middle), fill: child.equal?(@middle), padding: 0, ending: false)
            end
            set_show_close_button(false)
          end

          # Header actions retain their own callbacks and window attribution.
          def pack_start(child)
            @start.pack_start(child, expand: false, fill: false)
            self
          end
          alias add pack_start

          def pack_end(child)
            @end.pack_end(child, expand: false, fill: false)
            self
          end

          def set_title(value)
            @title_label.text = value
            self
          end
          alias title= set_title
          def title = @title_label.text

          def custom_title
            @custom_title if @custom_title&.parent.equal?(@middle)
          end

          # Script-owned actions can be detached and reused without exposing slots.
          def remove(child)
            if child.equal?(custom_title) && child
              set_custom_title(nil)
            elsif child.is_a?(Widget) && [@start, @end].include?(child.parent)
              child.parent.remove(child)
            else
              session.refuse(self, :remove)
            end
            self
          end

          # Replacement detaches the old title without destroying a script-held widget.
          def set_custom_title(child)
            session.synchronize do
              session.refuse(self, :set_custom_title) if destroyed?
              session.refuse(self, :set_custom_title) unless child.nil? || child.is_a?(Widget)
              return self if @middle.children.include?(child || @title_label)

              if child
                valid = child.is_a?(Widget) && child.session.equal?(session) && !child.destroyed? && !child.parent
                session.refuse(self, :set_custom_title) unless valid && !toplevel.equal?(child)
              end
              current = @middle.children.first
              @middle.add(child || @title_label)
              @middle.remove(current) if current
              @custom_title = child
            end
            self
          end
          alias custom_title= set_custom_title

          # A visible Close action uses Window#close, including delete-event vetoes.
          def set_show_close_button(value)
            session.refuse(self, :set_show_close_button) unless value == true || value == false
            @show_close_button = value
            value ? @close_button.show : @close_button.hide
            self
          end
          alias show_close_button= set_show_close_button
          def show_close_button? = @show_close_button

          def show_all
            super
            @close_button.hide unless @show_close_button
            self
          end
        end
      end
    end
  end
end
