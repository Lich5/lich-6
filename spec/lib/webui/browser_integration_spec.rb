# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'timeout'
require_relative '../../support/webui_browser'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'WebUI browser bootstrap', browser: true do
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
