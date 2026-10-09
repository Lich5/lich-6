# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'timeout'
require_relative '../../support/webui_browser'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'WebUI browser bootstrap', browser: true do
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
