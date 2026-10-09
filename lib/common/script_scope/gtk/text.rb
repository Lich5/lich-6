# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module WrapMode
          WORD = :word
          NONE = :none
        end

        # Plain text owned by one Script and at most one view. Draft text stays
        # in the core viewer store; buffer reads use the active callback's viewer.
        class TextBuffer
          Iter = Data.define(:buffer, :offset)
          MAX_LINES = 1000
          attr_reader :session

          # Creates an independent buffer. Rich tag tables are outside this adapter.
          # @param table [nil] no rich-text table is supported
          def initialize(table = nil)
            @session = Gtk.session
            session.refuse(self, :new) unless table.nil?
            @text = ''
            @handlers = []
          end

          # Returns a copy of the current viewer or retained text.
          # @return [String]
          def text = (@view ? @view.send(:buffer_text) : @text).dup
          def start_iter = Iter.new(self, 0)
          def end_iter = Iter.new(self, text.length)
          def char_count = text.length
          def line_count = text.count("\n") + 1
          def tag_table = self

          # Replaces text without confusing an append with a replacement.
          # Validation precedes both the renderer write and retained-state update.
          # @return [TextBuffer] self
          def set_text(value)
            session.synchronize do
              session.refuse(self, :text=) unless value.is_a?(String)
              target = bounded_text(value)
              changed = text != target || (@text != target && @notifying_text != target)
              @view&.send(:apply_buffer_text, target)
              @text = target.dup
              notify_changed if changed
            end
            self
          end
          alias text= set_text

          # Creates a buffer-local character offset, never a byte/browser offset.
          # @return [Iter]
          def get_iter_at_offset(offset)
            session.refuse(self, :get_iter_at_offset) unless offset.is_a?(Integer) && offset.between?(0, text.length)
            Iter.new(self, offset)
          end

          # Returns the start of an existing zero-based line.
          # @return [Iter]
          def get_iter_at_line(line)
            session.refuse(self, :get_iter_at_line) unless line.is_a?(Integer) && line.between?(0, line_count - 1)
            get_iter_at_offset(text.lines.first(line).sum(&:length))
          end

          # Inserts literal text at a valid buffer-local offset.
          # @return [TextBuffer] self
          def insert(iterator, value)
            session.synchronize do
              valid_iter!(iterator, :insert)
              session.refuse(self, :insert) unless value.is_a?(String)
              set_text(text.insert(iterator.offset, value))
            end
          end

          # Deletes a validated half-open range.
          # @return [TextBuffer] self
          def delete(first, last)
            session.synchronize do
              valid_range!(first, last, :delete)
              value = text
              value.slice!(first.offset...last.offset)
              set_text(value)
            end
          end

          # Reads a validated plain-text range. No hidden rich-text ranges exist.
          # @return [String]
          def get_text(first = start_iter, last = end_iter, include_hidden = false)
            session.refuse(self, :get_text) unless [true, false].include?(include_hidden)
            valid_range!(first, last, :get_text)
            text[first.offset...last.offset]
          end

          # Connects ordered notifications for programmatic or viewer changes.
          # @return [Integer] connection count
          def signal_connect(name, &block)
            session.refuse(self, "signal:#{name}") unless name.to_s == 'changed' && block
            @handlers << block
            @handlers.length
          end

          # Retains the previously accepted localchat color degradation only.
          # @return [TextBuffer] self
          def add(tag)
            session.refuse(self, :tag) unless tag.is_a?(TextTag)
            session.degrade(:text_colour, 'chat text colours follow the browser theme')
            self
          end

          # Checks localchat's color range without widening rich-text support.
          # @return [TextBuffer] self
          def apply_tag(tag, first, last)
            session.refuse(self, :apply_tag) unless tag.is_a?(TextTag)
            valid_range!(first, last, :apply_tag)
            self
          end

          # Binds one same-session view; ambiguous shared editable buffers refuse.
          # @api private
          def bind(view)
            session.refuse(self, :bind) unless view.session.equal?(session) && (!@view || @view.equal?(view))
            previous = @view
            begin
              @view = view
              view.send(:apply_buffer_text, bounded_text(@text))
            rescue StandardError
              @view = previous
              raise
            end
          end

          # Releases a replaced buffer while preserving its latest retained value.
          # @api private
          def unbind(view, retained: text)
            return unless @view.equal?(view)
            @text = retained
            @view = nil
          end

          # Delivers a validated viewer change without storing another draft copy.
          # Reentrant matching writes reuse the notification already in progress.
          # @api private
          def notify_changed
            session.synchronize do
              previous = @notifying_text
              @notifying_text = text
              @handlers.dup.each { |handler| handler.call(self) }
            ensure
              @notifying_text = previous
            end
          end

          # Refuses unimplemented marks, rich ranges and cursor editing explicitly.
          def method_missing(name, *, **, &)
            session.refuse(self, name)
          end

          def respond_to_missing?(*args) = super

          private

          def bounded_text(value)
            if @view&.send(:log?)
              lines = value.split("\n", -1)
              session.refuse(self, :text) if lines.any? { |line| line.length > Lich::WebUI::Contract::BOUNDS[:log_line] }
              if lines.length > MAX_LINES
                session.degrade(:text_history, 'compatibility text history retains the latest 1000 lines')
                lines = lines.last(MAX_LINES)
              end
              lines.join("\n")
            else
              session.refuse(self, :text) if value.length > Lich::WebUI::Contract::BOUNDS[:multiline_text]
              value
            end
          end

          def valid_iter!(iterator, operation)
            valid = iterator.is_a?(Iter) && iterator.buffer.equal?(self) && iterator.offset.between?(0, text.length)
            session.refuse(self, operation) unless valid
          end

          def valid_range!(first, last, operation)
            [first, last].each { |iterator| valid_iter!(iterator, operation) }
            session.refuse(self, operation) unless first.offset <= last.offset
          end
        end

        class TextTag
          # Accepts the existing bounded localchat color token; never raw CSS.
          def foreground=(colour)
            Gtk.session.refuse(self, :foreground=) unless colour.is_a?(String) && colour.match?(/\A(?:#[0-9a-fA-F]{6}|[a-zA-Z]+)\z/)
          end
        end

        # Editable plain text uses textarea; explicitly read-only views created
        # before publication retain the bounded log contract and history capacity.
        class TextView < Widget
          attr_reader :buffer

          # Creates a view for an independent buffer, or a fresh buffer by default.
          # @param buffer [TextBuffer, nil]
          def initialize(buffer = nil)
            super()
            @editable = true
            @log = false
            @props.merge!(value: '', read_only: false, wrap: :word, follow: false)
            set_buffer(buffer || TextBuffer.new)
          end

          # Rebinds a same-owner buffer without retaining its former view listener.
          # @return [TextView] self
          def set_buffer(buffer)
            return self if @buffer.equal?(buffer)

            session.synchronize do
              session.refuse(self, :buffer=) unless buffer.is_a?(TextBuffer) && buffer.session.equal?(session)
              retained = @buffer&.text
              buffer.bind(self)
              @buffer&.unbind(self, retained: retained) unless @buffer.equal?(buffer)
              @buffer = buffer
            end
            self
          end
          alias buffer= set_buffer

          # Selects log presentation before publication, or textarea read-only mode.
          # A published log cannot become an editor without replacing the view.
          # @return [TextView] self
          def set_editable(value)
            session.refuse(self, :editable=) unless [true, false].include?(value)
            session.refuse(self, :editable=) if @handle && @log && value
            unless @handle
              retained = @buffer.text
              @log = !value
              @props[:follow] = @log
              apply_buffer_text(retained)
            end
            @editable = value
            write(:read_only, !value) unless @log
            self
          end
          alias editable= set_editable
          def editable? = @editable

          # Cursor visibility applies only to editable text; log views have no cursor.
          def set_cursor_visible(value)
            session.refuse(self, :cursor_visible=) unless [true, false].include?(value)
            session.refuse(self, :cursor_visible=) if @log && value
            write(:cursor_visible, value) unless @log
            self
          end
          alias cursor_visible= set_cursor_visible

          # Supports literal word wrapping or unwrapped text.
          def set_wrap_mode(value)
            session.refuse(self, :wrap_mode=) unless %i[word none].include?(value)
            write(:wrap, value)
          end
          alias wrap_mode= set_wrap_mode

          # Preserves the existing explicit chat-font degradation.
          def override_font(font)
            session.refuse(self, :override_font) unless font.is_a?(Pango::FontDescription)
            session.degrade(:font_face, 'chat font face and size follow browser theme')
          end

          # Enables follow-to-end for the accepted legacy scrolling form.
          def scroll_to_iter(iterator, margin, align, x, y)
            valid = iterator.is_a?(TextBuffer::Iter) && iterator.buffer.equal?(@buffer) && iterator.offset == @buffer.end_iter.offset
            session.refuse(self, :scroll_to_iter) unless valid && margin == 0.0 && align == true && x == 0 && y == 0
            write(:follow, true)
          end

          protected

          def log? = @log
          def component_type = @log ? :log : :textarea
          def input_property = @log ? nil : :value
          def signal_map = @log ? {} : { 'changed' => :change }
          def buffer_text = @log ? @props.fetch(:lines, []).join("\n") : read(:value)

          def component_props
            @log ? super.except(:value, :read_only, :cursor_visible).merge(max_lines: TextBuffer::MAX_LINES) : super.except(:lines)
          end

          def apply_buffer_text(text)
            if @log
              lines = text.split("\n", -1)
              session.refuse(self, :text) if lines.length > TextBuffer::MAX_LINES || lines.any? { |line| line.length > Lich::WebUI::Contract::BOUNDS[:log_line] }
              write(:lines, lines)
            else
              write(:value, text)
            end
          end

          def bind_event(event)
            return super unless event == :change
            session.port.bind(@handle, event, proc do |context|
              session.callback(context, widget: self) do
                @buffer.notify_changed
                emit_handlers(:change)
              end
            end)
          end
        end

        # Plain expandable content delegates open state to the existing viewer store.
        class Expander < Widget
          def initialize(label = '')
            super()
            @props.merge!(label: String(label), open: false)
          end

          def label = read(:label)
          def set_label(value) = write(:label, String(value))
          alias label= set_label
          def expanded? = read(:open)
          alias expanded expanded?

          # Explicit writes notify only when the effective expanded state changes.
          def set_expanded(value)
            changed = expanded? != !!value
            write(:open, !!value)
            emit_handlers(:toggle) if changed
            self
          end
          alias expanded= set_expanded

          # GtkExpander is a single-child container, unlike the core expander.
          def add(child)
            session.refuse(self, :add) unless children.empty? || children.include?(child)
            super
          end

          protected

          def component_type = :expander
          def input_property = :open
          def signal_map = { 'notify::expanded' => :toggle }
        end
      end
    end
  end
end
