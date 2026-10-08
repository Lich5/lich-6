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

          # Creates an empty append-only text buffer owned by one compatibility log view.
          def initialize(view)
            @view = view
            @text = ''
          end

          # Returns a buffer-local offset at the current append position.
          # @return [Iter]
          def end_iter = Iter.new(self, @text.length)
          # Exposes this buffer as the limited tag-registration facade.
          # @return [TextBuffer] self
          def tag_table = self

          # Creates an iterator within the current buffer bounds.
          # @return [Iter]
          # @raise [UnsupportedOperation] for invalid offsets
          def get_iter_at_offset(offset)
            @view.session.refuse(self, :get_iter_at_offset) unless offset.is_a?(Integer) && offset.between?(0, @text.length)
            Iter.new(self, offset)
          end

          # Appends plain text at this buffer's end and retains at most the latest 1,000 lines.
          # Long individual lines are refused; history truncation is reported once per session.
          # @return [TextBuffer] self
          # @raise [UnsupportedOperation] for foreign/stale iterators or oversized lines
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

          # Accepts a text tag without retaining per-line objects; colors follow the browser theme.
          # @return [TextBuffer] self
          def add(tag)
            @view.session.refuse(self, :tag) unless tag.is_a?(TextTag)
            # Tags carry no executable style. Do not retain one object per line.
            @view.session.degrade(:text_colour, 'chat text colours follow the browser theme')
            self
          end

          # Checks tag/range compatibility without sending executable markup or style.
          # @return [TextBuffer] self
          # @raise [UnsupportedOperation] for foreign or invalid ranges
          def apply_tag(tag, first, last)
            valid = tag.is_a?(TextTag) && [first, last].all? { |it| it.is_a?(Iter) && it.buffer.equal?(self) }
            valid &&= first.offset.between?(0, last.offset) && last.offset <= @text.length
            @view.session.refuse(self, :apply_tag) unless valid
            self
          end
        end

        class TextTag
          # Checks a simple color spelling without applying arbitrary CSS to text.
          # @raise [UnsupportedOperation] for unsupported spellings
          def foreground=(colour)
            Gtk.session.refuse(self, :foreground=) unless colour.is_a?(String) && colour.match?(/\A(?:#[0-9a-fA-F]{6}|[a-zA-Z]+)\z/)
          end
        end

        class TextView < Widget
          attr_reader :buffer

          # Creates a read-only, following log backed by the bounded TextBuffer.
          def initialize
            super
            @props.merge!(lines: [], max_lines: TextBuffer::MAX_LINES, follow: true)
            @buffer = TextBuffer.new(self)
          end

          # Accepts read-only mode only; editable text views are outside the shim contract.
          # @raise [UnsupportedOperation] unless value is false
          def editable=(value)
            session.refuse(self, :editable=) unless value == false
          end

          # Accepts a hidden editing cursor only.
          # @raise [UnsupportedOperation] unless value is false
          def cursor_visible=(value)
            session.refuse(self, :cursor_visible=) unless value == false
          end

          # Accepts the measured word-wrap mode only.
          # @raise [UnsupportedOperation] for other modes
          def wrap_mode=(value)
            session.refuse(self, :wrap_mode=) unless value == WrapMode::WORD
          end

          # Validates the font token while reporting that chat face/size follow the browser theme.
          # @raise [UnsupportedOperation] for noncompatibility font objects
          def override_font(font)
            session.refuse(self, :override_font) unless font.is_a?(Pango::FontDescription)
            session.degrade(:font_face, 'chat font face and size follow browser theme')
          end

          # Enables following only for the measured scroll-to-end argument combination.
          # @return [TextView] self
          # @raise [UnsupportedOperation] for other scrolling requests
          def scroll_to_iter(iterator, margin, align, x, y)
            valid = iterator.is_a?(TextBuffer::Iter) && iterator.buffer.equal?(@buffer) && iterator.offset == @buffer.end_iter.offset
            session.refuse(self, :scroll_to_iter) unless valid && margin == 0.0 && align == true && x == 0 && y == 0
            write(:follow, true)
          end

          protected

          def component_type = :log
        end

        # Use the contracted split primitive: the first child's natural width
        # establishes the initial divider, and the viewer owns later dragging.
        class Paned < Box
          # Creates the supported horizontal split using the common layout contract.
          # @raise [UnsupportedOperation] for other orientations
          def initialize(orientation)
            super(orientation)
            session.refuse(self, :new) unless orientation == :horizontal
          end

          # Adds the first split child only while the split is empty.
          # @return [Paned] self
          def add1(child)
            session.refuse(self, :add1) unless children.empty?
            add(child)
          end

          # Adds the second split child only after the first exists.
          # @return [Paned] self
          def add2(child)
            session.refuse(self, :add2) unless children.length == 1
            add(child)
          end

          protected

          def component_type = :split
          def component_props = super.except(:cols, :gap).merge(orientation: :horizontal)
          def builtin_events = [:move]
        end

        class Overlay < Widget
          alias add_overlay add

          protected

          def component_type = :overlay
        end

        class ProgressBar < Widget
          # Initializes a progress control at an empty fraction.
          def initialize
            super
            @props[:value] = 0.0
          end

          # Bounds the displayed fraction without changing the script's arithmetic.
          # NaN has no representable WebUI fraction; retain the last display value
          # and report that degradation once rather than aborting the whole update.
          # @param value [Numeric] requested fraction; infinities saturate at an end
          # @return [ProgressBar] this progress bar
          # @raise [UnsupportedOperation] when the value is not a real number
          def set_fraction(value)
            session.refuse(self, :set_fraction) unless value.is_a?(Numeric) && value.real?
            fraction = value.to_f
            if fraction.nan?
              session.degrade(:progress_fraction_nan, 'undefined fraction; retaining the last displayed value')
              return self
            end

            write(:value, fraction.clamp(0.0, 1.0))
          end

          # Returns the cached bounded progress-style facade for this widget.
          # @return [StyleContext]
          def style_context = @style_context ||= StyleContext.new(self)

          protected

          def component_type = :progress
        end
      end
    end
  end
end
