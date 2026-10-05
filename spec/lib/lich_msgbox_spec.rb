# frozen_string_literal: true

require 'rspec'
require 'open3'
require 'rbconfig'

RSpec.describe 'Lich.msgbox without a graphical toolkit' do
  it 'reports bootstrap errors on stderr without loading GTK' do
    source = <<~'SOURCE'
      LICH_VERSION = 'test'
      require ARGV[0]
      puts Lich.msgbox(message: 'Unavailable frontend').inspect
      abort 'GTK loaded' if defined?(Gtk)
    SOURCE
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-e', source, File.expand_path('../../lib/lich.rb', __dir__)
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq('nil')
    expect(stderr.strip).to eq('Unavailable frontend')
  end
end
