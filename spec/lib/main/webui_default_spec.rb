# frozen_string_literal: true

require_relative '../../spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'default native WebUI startup' do
  it 'activates script-local compatibility through both real script binding entrypoints' do
    source = <<~RUBY
      require_relative 'lib/common/script'
      bindings = [Lich::Common::TRUSTED_SCRIPT_BINDING.call, Lich::Common::Scripting.new.script]
      abort 'shim missing' unless bindings.all? { |scope| eval('Gtk::Version::MAJOR == 3 && HAVE_GTK', scope) }
      abort 'core GTK leaked' if [Object, Lich::Common].any? { |scope| scope.const_defined?(:Gtk, false) }
      abort 'GTK gem loaded' if $LOADED_FEATURES.any? { |path| path.include?('/gtk3') }
    RUBY
    _, stderr, status = Open3.capture3(RbConfig.ruby, '-e', source, chdir: File.expand_path('../../..', __dir__))

    expect(status).to be_success, stderr
  end

  it 'routes the graphical startup path through the native launcher' do
    options = File.read(File.join(LIB_DIR, 'main', 'argv_options.rb'))
    main = File.read(File.join(LIB_DIR, 'main', 'main.rb'))

    expect(options).not_to include('webui_dev')
    expect(main).to include('elsif ARGV.empty? or @argv_options[:gui]')
    expect(main).to include("require File.join(LIB_DIR, 'common', 'webui_launcher.rb')")
    expect(main).to include("@launch_data = webui_launcher.start.await_launch\n    next unless @launch_data")
    expect(main).not_to include('gui_login')
    expect(main).not_to match(/\bGtk(?:::|\.)/)
  end

  it 'loads no core GTK runtime or main loop from the executable path' do
    entrypoint = File.read(File.expand_path('../../../lich.rbw', __dir__))
    init = File.read(File.join(LIB_DIR, 'init.rb'))

    expect(entrypoint).to include('@main_thread.join')
    expect(entrypoint).not_to match(/common.*gtk|gtk_compaction|Gtk\.main/)
    expect(init).not_to match(/require ['"]gtk3|HAVE_GTK/)
  end

  it 'keeps core independent of the future compatibility shim' do
    launcher = File.read(File.join(LIB_DIR, 'common', 'webui_launcher.rb'))
    main = File.read(File.join(LIB_DIR, 'main', 'main.rb'))

    expect([launcher, main].join("\n")).not_to include('script_scope/gtk')
  end
end
