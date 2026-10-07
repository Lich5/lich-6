# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'GTK-free Ruby dependency boundary' do
  let(:scope) { Lich::Common::ScriptScope }

  before do
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(nil)
  end

  it 'refuses native entrypoints outside script ownership instead of loading installed gems' do
    %w[gtk3 glib2 cairo gobject-introspection gtk4 gdk3 pango].each do |feature|
      expect { Kernel.require(feature) }.to raise_error(scope::Gtk::UnsupportedOperation, /script=none.*native GTK loading is disabled/)
    end
  end

  it 'rejects absolute loads, relative loads and native extensions before executing them' do
    Dir.mktmpdir('gtk-load-boundary') do |root|
      File.write(File.join(root, 'gtk3.rb'), 'raise "native sentinel executed"')
      File.write(File.join(root, 'relative_probe.rb'), "require_relative 'gtk3'\n")
      [-> { Kernel.load(File.join(root, 'gtk3.rb')) },
       -> { Kernel.require(File.join(root, 'relative_probe.rb')) },
       -> { Kernel.require('gtk3.bundle') },
       -> { Kernel.require('gtk3/loader') }].each do |load|
        expect(&load).to raise_error(scope::Gtk::UnsupportedOperation, /native GTK loading is disabled/)
      end
    end
  end

  it 'preserves ordinary helper loading, relative resolution, return values and wrapped loads' do
    Dir.mktmpdir('ordinary-load-boundary') do |root|
      stub_const('DEPENDENCY_BOUNDARY_EVENTS', [])
      File.write(File.join(root, 'child.rb'), 'DEPENDENCY_BOUNDARY_EVENTS << :child')
      helper = File.join(root, 'helper.rb')
      File.write(helper, "DEPENDENCY_BOUNDARY_EVENTS << require_relative('child')\n")
      expect(Kernel.require(helper)).to be(true)
      expect(Kernel.require(helper)).to be(false)
      expect(Kernel.load(helper, true)).to be(true)
      expect(DEPENDENCY_BOUNDARY_EVENTS).to eq([:child, true, false])
    end
  end

  it 'keeps Kernel instance loaders private and explicit module loaders public' do
    expect(Kernel.private_instance_methods).to include(:require, :require_relative, :load)
    expect(Kernel.public_methods).to include(:require, :require_relative, :load)
  end
end
