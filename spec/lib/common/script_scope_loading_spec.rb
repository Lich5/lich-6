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
    Dir.mktmpdir('gtk-entrypoints') do |root|
      %w[gtk3 glib2 gio2 cairo cairo-gobject cairo_gobject gobject-introspection gobject_introspection
         gi gtk4 gdk3 gdk_pixbuf2 pango atk].each do |feature|
        target = File.join(root, "#{feature}.rb")
        File.write(target, 'raise "native entrypoint sentinel executed"')
        expect { Kernel.require(target) }.to raise_error(scope::Gtk::UnsupportedOperation, /script=none.*native GTK loading is disabled/)
      end
    end
  end

  %w[gdk_pixbuf2/loader gdk_pixbuf2/pixbuf-loader gobject_introspection cairo_gobject gi].each do |feature|
    it "refuses #{feature} before executing a direct subload" do
      Dir.mktmpdir('gtk-direct-subload') do |root|
        stub_const('GTK_SUBLOAD_EXECUTED', [])
        target = File.join(root, "#{feature}.rb")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, 'GTK_SUBLOAD_EXECUTED << true')

        expect { Kernel.require(target) }.to raise_error(scope::Gtk::UnsupportedOperation, /native GTK loading is disabled/)
        expect(GTK_SUBLOAD_EXECUTED).to be_empty
        expect($LOADED_FEATURES).not_to include(target)
      end
    end
  end

  it 'refuses platform extension spellings of the GTK dependency stack' do
    %w[gtk2 gtk3 gtk4 gdk2 gdk3 gdk4 gdk_pixbuf2 glib2 gio2 gobject_introspection cairo cairo_gobject pango atk].each do |feature|
      %w[so bundle dll].each do |extension|
        # Inspect the guard directly: a regression must not load installed binaries.
        expect do
          scope::Gtk::RequireBoundary.handled?("#{feature}.#{extension}", :require, caller_locations(0, 1).first)
        end.to raise_error(scope::Gtk::UnsupportedOperation)
      end
    end
  end

  it 'guards Ruby autoload when the deferred native feature is resolved' do
    Dir.mktmpdir('gtk-autoload') do |root|
      stub_const('GTK_AUTOLOAD_EXECUTED', [])
      target = File.join(root, 'gdk_pixbuf2.rb')
      File.write(target, 'GTK_AUTOLOAD_EXECUTED << true')
      namespace = Module.new
      namespace.autoload(:NativeProbe, target)

      expect { namespace.const_get(:NativeProbe) }.to raise_error(scope::Gtk::UnsupportedOperation)
      expect(GTK_AUTOLOAD_EXECUTED).to be_empty
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
