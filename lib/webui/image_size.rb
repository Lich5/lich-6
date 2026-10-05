# frozen_string_literal: true

module Lich
  module WebUI
    # Native map and creature image consumers need dimensions, not decoding or
    # a GTK image object. Read at most 1 MiB of headers; pixels stay in the browser.
    # PNG/GIF/JPEG are the existing consumers' formats. Unknown formats refuse.
    module ImageSize
      HEADER_LIMIT = 1_048_576
      JPEG_FRAMES = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].freeze

      def self.read(path)
        bytes = File.open(path, 'rb') { |file| file.read(HEADER_LIMIT) }
        size = if bytes&.start_with?([137, 80, 78, 71, 13, 10, 26, 10].pack('C*')) && bytes.byteslice(12, 4) == 'IHDR' && bytes.bytesize >= 24
                 bytes.byteslice(16, 8).unpack('NN')
               elsif bytes && %w[GIF87a GIF89a].include?(bytes.byteslice(0, 6)) && bytes.bytesize >= 10
                 bytes.byteslice(6, 4).unpack('vv')
               elsif bytes&.start_with?([255, 216].pack('C*'))
                 jpeg_dimensions(bytes)
               end
        raise ArgumentError, 'Unsupported or truncated image header (expected PNG, GIF or JPEG)' unless size
        raise ArgumentError, 'Image dimensions must be within 1..65536 pixels' unless size.all? { |value| value.between?(1, 65_536) }

        size.freeze
      end

      def self.jpeg_dimensions(bytes)
        offset = 2
        while offset + 4 <= bytes.bytesize
          return unless bytes.getbyte(offset) == 0xff

          offset += 1 while bytes.getbyte(offset) == 0xff
          marker = bytes.getbyte(offset)
          offset += 1
          return if marker.nil? || [0xda, 0xd9].include?(marker)
          next if marker == 0x01 || (0xd0..0xd7).cover?(marker)

          length = bytes.byteslice(offset, 2)&.unpack1('n')
          return unless length && length >= 2 && offset + length <= bytes.bytesize
          if JPEG_FRAMES.include?(marker)
            return unless length >= 8

            height, width = bytes.byteslice(offset + 3, 4).unpack('nn')
            return [width, height]
          end
          offset += length
        end
        nil
      end
      private_class_method :jpeg_dimensions
    end
  end
end
