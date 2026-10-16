# frozen_string_literal: true

require_relative '../../spec_helper'
require 'tempfile'

RSpec.describe 'native image dimensions' do
  def bmp(width = 2, height = 3, depth = 24)
    pixels = "\0".b * (((width * depth + 31) / 32) * 4 * height.abs)
    'BM'.b + [54 + pixels.bytesize, 0, 54, 40, width, height, 1, depth, 0, pixels.bytesize, 0, 0, 0, 0].pack('VVVVl<l<vvVVl<l<VV') + pixels
  end

  def dimensions(bytes)
    Tempfile.create('webui-image') do |file|
      file.binmode
      file.write(bytes)
      file.flush
      Lich::WebUI::ImageSize.read(file.path)
    end
  end

  it 'reads PNG and GIF dimensions without a graphics dependency' do
    require 'webui/image_size'
    expect(dimensions([137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + [13].pack('N') + 'IHDR' + [640, 480].pack('NN'))).to eq([640, 480])
    expect(dimensions('GIF89a' + [32, 48].pack('vv'))).to eq([32, 48])
  end

  it 'reads padded RGB BMP rows and top-down or 32-bit true-color images' do
    require 'webui/image_size'
    expect(dimensions(bmp)).to eq([2, 3])
    zero_size = bmp
    zero_size[34, 4] = [0].pack('V')
    expect(dimensions(zero_size)).to eq([2, 3])
    expect(dimensions(bmp(2, -3, 32))).to eq([2, 3])
    expect(dimensions(bmp(1024, 400))).to eq([1024, 400])
  end

  it 'refuses unsupported BMP variants, invalid offsets and truncated pixel rows' do
    require 'webui/image_size'
    [[14, [12].pack('V')], [26, [2].pack('v')], [28, [8].pack('v')],
     [30, [1].pack('V')], [10, [53].pack('V')], [10, [500].pack('V')],
     [2, [54].pack('V')], [34, [1].pack('V')]].each do |offset, replacement|
      malformed = bmp
      malformed[offset, replacement.bytesize] = replacement
      expect { dimensions(malformed) }.to raise_error(ArgumentError, /image/)
    end
    expect { dimensions(bmp.byteslice(0, 53)) }.to raise_error(ArgumentError, /image/)
    expect { dimensions(bmp.byteslice(0...-1)) }.to raise_error(ArgumentError, /image/)
    expect { dimensions(bmp(65_537, 1)) }.to raise_error(ArgumentError, /dimensions/)
  end

  it 'skips JPEG metadata segments and reads a start-of-frame header' do
    require 'webui/image_size'
    jpeg = [255, 216, 255, 224].pack('C*') + [6].pack('n') + 'test' + [255, 192].pack('C*') + [8, 8, 120, 160, 1].pack('nCnnC')
    expect(dimensions(jpeg)).to eq([160, 120])
  end

  it 'rejects truncated, unsupported and oversized images explicitly' do
    require 'webui/image_size'
    expect { dimensions('GIF89a') }.to raise_error(ArgumentError, /image/)
    expect { dimensions('arbitrary text') }.to raise_error(ArgumentError, /image/)
    expect { dimensions('GIF89a' + [0, 20].pack('vv')) }.to raise_error(ArgumentError, /dimensions/)
  end
end
