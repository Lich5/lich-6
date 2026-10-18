# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'timeout'
require_relative '../../support/webui_browser'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'WebUI browser bootstrap', browser: true do
  it 'sizes and lays out native tab actions without changing indexed panels' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    service = Lich::WebUI::Service.new
    owner = Object.new
    mode = :sized
    status = 'Native help idle'
    page = nil
    switch = proc { mode = mode == :sized ? :account : :sized; service.refresh(page) }
    help = proc { status = 'Native help activated'; service.refresh(page) }
    page = Lich::WebUI::Page.new(owner: owner, id: 'native-tab-actions', title: 'Native tab actions', props: { density: :compact }) do |ui|
      ui.tabs key: mode == :sized ? 'sized-tabs' : 'saved-account-tabs', names: %w[One Two], selected: 1, size_to_all: mode == :sized do
        text key: 'one', content: 'A much larger sizing page', slot: 'One', height: 240
        text key: 'two', content: 'Selected native page', slot: 'Two'
        button key: 'help', label: 'Native help', placement: { tab_action: :end }, on: { activate: help }
      end
      ui.text content: status
      ui.button label: 'Switch tab layout', on: { activate: switch }
    end
    service.registry.register(page)
    WebUIBrowser.check(service: service, page: page, scenario: 'native-notebook-actions')
  ensure
    service&.stop
  end

  it 'serves and decodes a BMP through the authenticated image route' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    Dir.mktmpdir('webui-bmp') do |root|
      bytes = 'BM'.b + [62, 0, 54, 40, 2, 1, 1, 24, 0, 8, 0, 0, 0, 0].pack('VVVVl<l<vvVVl<l<VV') + "\0".b * 8
      File.binwrite(File.join(root, 'fixture.bmp'), bytes)
      service = Lich::WebUI::Service.new(application_roots: [root])
      owner = Object.new
      prefix = service.register_files('bmp', root, owner: owner)
      page = Lich::WebUI::Page.new(owner: owner, id: 'bmp', title: 'BMP image') do |ui|
        ui.image src: prefix + 'fixture.bmp', alt: 'BMP fixture'
      end
      service.registry.register(page)
      WebUIBrowser.check(service: service, page: page, scenario: 'native-bmp')
    ensure
      service&.stop
    end
  end

  it 'clips Layout children at negative coordinates and moves them into the canvas' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    scope = Lich::Common::ScriptScope
    scope.activate!
    owner = Struct.new(:name).new('layout.lic')
    service = Lich::WebUI::Service.new
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich).to receive(:log)
    gtk = scope.const_get(:Gtk, false)
    window, layout = gtk::Window.new, gtk::Layout.new
    layout.set_margin_left(140)
    hidden, move = gtk::Button.new('Offscreen'), gtk::Button.new('Move into canvas')
    hidden.set_size_request(100, 30)
    anchor = gtk::Label.new('Canvas extent')
    anchor.set_size_request(240, 60)
    layout.put(hidden, -120, 50)
    layout.put(anchor, 0, 120)
    layout.put(move, 0, 0)
    move.signal_connect('clicked') { layout.move(hidden, 100, 50) }
    window.add(layout)
    window.show_all
    page = nil
    Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-layout')
  ensure
    Lich::Common::ScriptDeath.run(owner) if owner
    service&.stop
  end

  it 'measures Fixed children, delivers EventBox clicks and applies focus requests once' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    scope = Lich::Common::ScriptScope
    scope.activate!
    owner = Struct.new(:name).new('fixed-events-focus.lic')
    service = Lich::WebUI::Service.new
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich).to receive(:log)
    gtk = scope.const_get(:Gtk, false)
    window, fixed = gtk::Window.new, gtk::Fixed.new
    first, second = gtk::Entry.new, gtk::Entry.new
    first.placeholder_text = 'First field'
    second.placeholder_text = 'Second field'
    surface = gtk::EventBox.new
    label = gtk::Label.new('Pointer surface')
    status = gtk::Label.new('Waiting for edit')
    second.signal_connect('changed') { status.text = 'Edited second' }
    surface.add(label)
    clicks, saved = [], nil
    surface.signal_connect('button_press_event') do |_widget, event|
      clicks << event.button
      label.text = "Pointer #{event.button}"
      fixed.move(surface, 350, 40)
    end
    refocus, finish = gtk::Button.new('Refocus'), gtk::Button.new('Finish')
    refocus.signal_connect('clicked') { window.set_focus(first) }
    finish.signal_connect('clicked') { saved = second.text; window.destroy }
    [[first, 0, 0], [second, 0, 60], [surface, 300, 0], [refocus, 0, 120], [finish, 150, 120], [status, 0, 180]].each do |child, x, y|
      fixed.put(child, x, y)
    end
    window.add(fixed)
    window.set_focus(first)
    window.show_all
    page = nil
    Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-fixed-events-focus')
    expect(clicks).to eq([1])
    expect(saved).to eq('Changed second')
  ensure
    Lich::Common::ScriptDeath.run(owner) if owner
    service&.stop
  end

  it 'keeps progress dimensions and labels stable when color overrides change' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    service = Lich::WebUI::Service.new
    colored = true
    finished = false
    page = Lich::WebUI::Page.new(owner: Object.new, id: 'progress-sizing', title: 'Core progress sizing') do |ui|
      ui.text content: 'Same core control: plain, colored, labeled and pending'
      [18, 24, 36].each do |height|
        ui.progress key: "plain-#{height}", value: 0.5, width: 300, height: height
        props = colored ? { fill_color: { r: 176, g: 224, b: 230, a: 1 } } : {}
        ui.progress key: "colored-#{height}", value: 0.5, width: 300, height: height, **props
      end
      ui.progress key: 'labeled', value: 0.5, label: 'Visible progress label', width: 300, height: 48
      ui.progress key: 'pending', indeterminate: true, width: 300, height: 24
      ui.progress key: 'default', value: 0.5, width: 300
      ui.button label: 'Toggle colors', on: { activate: lambda { |_event|
        colored = !colored
        service.runtime.refresh(page)
      } }
      ui.button label: 'Finish', on: { activate: lambda { |_event|
        finished = true
        service.runtime.close_page(page)
        service.close_window(page)
      } }
    end
    service.registry.register(page)
    page.bind_runtime(service.runtime)
    page.render
    WebUIBrowser.check(service: service, page: page, scenario: 'native-progress-sizing')
    expect(colored).to be(false)
    expect(finished).to be(true)
  ensure
    service&.stop
  end

  it 'round-trips model selection, tree expansion, cell edits and duplicate combo choices' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    scope = Lich::Common::ScriptScope
    scope.activate!
    owner = Struct.new(:name).new('browser-models.lic')
    service = Lich::WebUI::Service.new
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich).to receive(:log)
    gtk = scope.const_get(:Gtk, false)
    window = gtk::Window.new
    store = gtk::TreeStore.new(String, TrueClass)
    root = store.append
    root[0] = 'Parent'
    child = store.append(root)
    child[0] = 'Child'
    view = gtk::TreeView.new(store)
    view.selection.mode = :multiple
    text, toggle = gtk::CellRendererText.new, gtk::CellRendererToggle.new
    text.editable = true
    text.signal_connect('edited') { |_renderer, path, value| store.get_iter(path)[0] = value }
    toggle.signal_connect('toggled') { |_renderer, path| iter = store.get_iter(path); iter[1] = !iter[1] }
    view.append_column(gtk::TreeViewColumn.new('Name', text, text: 0))
    view.append_column(gtk::TreeViewColumn.new('Enabled', toggle, active: 1))
    choices = gtk::ListStore.new(String, String)
    %w[first second].each { |id| iter = choices.append; iter[0], iter[1] = id, 'Duplicate' }
    combo = gtk::ComboBox.new(choices, entry: true)
    combo.entry_text_column = 1
    status = gtk::Label.new('Awaiting model callback')
    save = gtk::Button.new('Read models')
    result = nil
    save.signal_connect('clicked') do
      result = [child[0], child[1], combo.active_iter[0], view.row_expanded?('0'), view.selection.count_selected_rows]
      status.text = result.join(' / ')
    end
    [view, combo, save, status].each { |widget| window.add(widget) }
    window.show_all
    page = nil
    Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-models')
    expect(result).to eq(['Edited child', true, 'second', true, 2])
  ensure
    Lich::Common::ScriptDeath.run(owner) if owner
    service&.stop
  end

  it 'loads a native page through the private file and delivers its callback' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    service = Lich::WebUI::Service.new
    activated = false
    page = Lich::WebUI::Page.new(owner: Object.new, id: 'bootstrap', title: 'Browser fixture') do |ui|
      ui.text key: 'status', content: activated ? 'Callback received' : 'Awaiting callback'
      # Placement aligns the whole text block; justification aligns its lines.
      %w[start center end].each do |align|
        ui.text key: "justified-#{align}", content: "Longer line\nshort", width: 240,
                align: align, line_justify: :right, wrap: false
      end
      ui.text key: 'justified-wrap', content: 'Longer line short', width: 80,
              align: :start, line_justify: :right, wrap: true
      ui.button key: 'activate', label: 'Activate', on: { activate: lambda { |_event|
        activated = true
        service.runtime.refresh(page)
      } }
    end
    service.registry.register(page)
    page.bind_runtime(service.runtime)
    page.render
    WebUIBrowser.check(service: service, page: page, scenario: 'native-bootstrap')
    expect(activated).to be(true)
  ensure
    service&.stop
  end
end
