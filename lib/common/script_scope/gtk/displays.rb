# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module WrapMode
          WORD = :word
        end

        # localchat and status-monitor append plain text; neither edits it.
        # Iterators are offsets in this buffer, never browser nodes or handles.
        class TextBuffer
          Iter = Data.define(:buffer, :offset)
          MAX_LINES = 1000

          def initialize(view)
            @view = view
            @text = ''
          end

          def end_iter = Iter.new(self, @text.length)
          def tag_table = self

          def get_iter_at_offset(offset)
            @view.session.refuse(self, :get_iter_at_offset) unless offset.is_a?(Integer) && offset.between?(0, @text.length)
            Iter.new(self, offset)
          end

          def insert(iterator, text)
            valid = iterator.is_a?(Iter) && iterator.buffer.equal?(self) && iterator.offset == @text.length
            @view.session.refuse(self, :insert) unless valid && text.is_a?(String)
            lines = (@text + text).split("\n", -1)
            @view.session.refuse(self, :insert) if lines.any? { |line| line.length > Lich::WebUI::Contract::BOUNDS[:log_line] }
            if lines.length > MAX_LINES
              @view.session.degrade(:text_history, 'compatibility text history retains the latest 1000 lines')
              lines = lines.last(MAX_LINES)
            end
            @text = lines.join("\n")
            @view.send(:write, :lines, lines)
            self
          end

          def add(tag)
            @view.session.refuse(self, :tag) unless tag.is_a?(TextTag)
            # Tags carry no executable style. Do not retain one object per line.
            @view.session.degrade(:text_colour, 'chat text colours follow the browser theme')
            self
          end

          def apply_tag(tag, first, last)
            valid = tag.is_a?(TextTag) && [first, last].all? { |it| it.is_a?(Iter) && it.buffer.equal?(self) }
            valid &&= first.offset.between?(0, last.offset) && last.offset <= @text.length
            @view.session.refuse(self, :apply_tag) unless valid
            self
          end
        end

        class TextTag
          def foreground=(colour)
            Gtk.session.refuse(self, :foreground=) unless colour.is_a?(String) && colour.match?(/\A(?:#[0-9a-fA-F]{6}|[a-zA-Z]+)\z/)
          end
        end

        class TextView < Widget
          attr_reader :buffer

          def initialize
            super
            @props.merge!(lines: [], max_lines: TextBuffer::MAX_LINES, follow: true)
            @buffer = TextBuffer.new(self)
          end

          def editable=(value)
            session.refuse(self, :editable=) unless value == false
          end

          def cursor_visible=(value)
            session.refuse(self, :cursor_visible=) unless value == false
          end

          def wrap_mode=(value)
            session.refuse(self, :wrap_mode=) unless value == WrapMode::WORD
          end

          def override_font(font)
            session.refuse(self, :override_font) unless font.is_a?(Pango::FontDescription)
            session.degrade(:font_face, 'chat font face and size follow browser theme')
          end

          def scroll_to_iter(iterator, margin, align, x, y)
            valid = iterator.is_a?(TextBuffer::Iter) && iterator.buffer.equal?(@buffer) && iterator.offset == @buffer.end_iter.offset
            session.refuse(self, :scroll_to_iter) unless valid && margin == 0.0 && align == true && x == 0 && y == 0
            write(:follow, true)
          end

          protected

          def component_type = :log
        end

        # spellson uses a two-part row; it does not move a GTK split handle.
        class Paned < Box
          def initialize(orientation)
            super(orientation)
            session.refuse(self, :new) unless orientation == :horizontal
          end

          def add1(child)
            session.refuse(self, :add1) unless children.empty?
            add(child)
          end

          def add2(child)
            session.refuse(self, :add2) unless children.length == 1
            add(child)
          end
        end

        class Overlay < Widget
          alias add_overlay add

          protected

          def component_type = :overlay
        end

        class ProgressBar < Widget
          def initialize
            super
            @props[:value] = 0.0
          end

          def set_fraction(value)
            session.refuse(self, :set_fraction) unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
            write(:value, value)
          end

          def style_context = @style_context ||= StyleContext.new

          protected

          def component_type = :progress
        end
      end
    end
  end
end
