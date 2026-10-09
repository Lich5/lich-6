# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # File-backed display values, not decoded or mutable pixel buffers.
        class FileImage
          attr_reader :session, :source, :width, :height

          # Reads supported image headers after the existing file-root policy accepts them.
          # Width/height specify display bounds; aspect ratio is preserved by default.
          # @param path [String, nil] legacy positional filename
          # @param file [String, nil] filename keyword
          # @param width [Integer, nil] requested width
          # @param height [Integer, nil] requested height
          # @param preserve_aspect_ratio [Boolean] fit within requested bounds
          def initialize(path = nil, file: path, width: nil, height: nil, preserve_aspect_ratio: true)
            @session = Gtk.session
            session.refuse(self, :new) unless file.is_a?(String) && [true, false].include?(preserve_aspect_ratio)
            real = File.realpath(file)
            @source = session.image_source(real).freeze
            original_width, original_height = Lich::WebUI::ImageSize.read(real)
            [width, height].compact.each { |number| dimension!(number) }
            @width, @height = width || original_width, height || original_height
            if preserve_aspect_ratio && (width || height)
              ratios = []
              ratios << width.fdiv(original_width) if width
              ratios << height.fdiv(original_height) if height
              ratio = ratios.min
              @width = [(original_width * ratio).round, 1].max
              @height = [(original_height * ratio).round, 1].max
            end
            dimension!(@width)
            dimension!(@height)
            freeze
          end

          # Returns a new display-size value. Browser interpolation is explicit;
          # this operation never creates resampled pixels or a writable image.
          # @return [FileImage]
          def scale_simple(width, height, interpolation = :bilinear)
            dimension!(width)
            dimension!(height)
            session.refuse(self, :scale_simple) unless interpolation == :bilinear
            scaled = dup
            scaled.instance_variable_set(:@width, width)
            scaled.instance_variable_set(:@height, height)
            scaled.freeze
          end
          alias scale scale_simple

          # Unsupported pixel/drawing/export operations never fall through to native code.
          def method_missing(name, *, **, &)
            session.refuse(self, name)
          end

          def respond_to_missing?(*args) = super

          private

          def dimension!(value)
            session.refuse(self, :dimensions) unless value.is_a?(Integer) && value.between?(1, 65_536)
          end
        end

        # An empty image is legitimate state; clearing removes the source request.
        class Image < Widget
          def initialize(source = nil, file: nil, pixbuf: nil)
            super()
            session.refuse(self, :new) if [source, file, pixbuf].compact.length > 1
            @props[:src] = ''
            source ||= file || pixbuf
            source.is_a?(String) ? set_from_file(source) : set_pixbuf(source) if source
          end

          # Replaces the image using the bounded file-backed compatibility value.
          # @return [Image] self
          def set_pixbuf(value)
            return clear if value.nil?
            session.refuse(self, :set_pixbuf) unless value.is_a?(FileImage) && value.session.equal?(session)
            session.synchronize do
              write(:width, value.width)
              write(:height, value.height)
              write(:src, value.source)
              @pixbuf = value
            end
            self
          end
          alias pixbuf= set_pixbuf
          alias set_from_pixbuf set_pixbuf
          attr_reader :pixbuf

          # Resolves a supported file through the existing authenticated route service.
          def set_from_file(path) = set_pixbuf(FileImage.new(file: path))
          alias file= set_from_file

          # Clears visible pixels and retained source without unregistering other images.
          def clear
            write(:src, '')
            @pixbuf = nil
            self
          end

          # The renderer already recomputes image layout on source/dimension changes.
          def queue_resize = self

          protected

          def component_type = :image
        end
      end

      module GdkPixbuf
        Pixbuf = Gtk::FileImage
        module InterpType
          BILINEAR = :bilinear
        end

        def self.const_missing(name)
          Gtk.session.refuse(self, name)
        end
      end

      module Gdk
        Pixbuf = Gtk::FileImage
        InterpType = GdkPixbuf::InterpType
      end
    end
  end
end
