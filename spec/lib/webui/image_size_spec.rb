# frozen_string_literal: true

require_relative '../../spec_helper'
require 'tempfile'

RSpec.describe 'native image dimensions' do
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
