# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'
require_relative '../../support/webui_browser'
require 'timeout'
require 'digest'

RSpec.describe 'bounded Gtk Builder compatibility' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('builder.lic') }
  let(:service) { Lich::WebUI::Service.new }
  let(:gtk) { scope.const_get(:Gtk, false) }
  let(:builder) { gtk::Builder.new }

  around do |example|
    Dir.mktmpdir('builder-settings-') do |directory|
      @settings_directory = directory
      example.run
    end
  end

  before do
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich).to receive(:log)
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
  end

  def load_xml(body)
    builder.add_from_string("<interface>#{body}</interface>")
  end

  # Run the original setup module with inert game lookups and an isolated save path.
  # Its XML, load_settings, change, Close and destroy handlers are not rewritten.
  def original_ecleanse(settings = {})
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:Util, double(get_script_version: 'fixture'))
    spells = Object.new
    spells.define_singleton_method(:[]) { |key| Struct.new(:known?).new(key != 113) }
    sandbox.const_set(:Spell, spells)
    sandbox.const_set(:CMan, double(known?: true, stun_maneuvers: 5))
    sandbox.const_set(:Feat, double(known?: true))
    sandbox.const_set(:DATA_DIR, @settings_directory)
    sandbox.const_set(:XMLData, double(game: 'GS'))
    sandbox.const_set(:Char, double(name: 'Fixture'))
    FileUtils.mkdir_p(File.join(@settings_directory, 'GS', 'Fixture'))
    @messages = []
    messages = @messages
    messaging = Module.new
    messaging.define_singleton_method(:msg) { |_type, message| messages << message }
    stub_const('Lich::Messaging', messaging)
    path = File.expand_path('../../fixtures/webui/ecleanse_setup.lic', __dir__)
    sandbox.module_eval(File.read(path), path)
    mod = sandbox.const_get(:Ecleanse)
    mod.define_singleton_method(:data) { Struct.new(:settings).new(settings) }
    klass = mod.const_get(:Setup)
    klass.define_method(:respond) { |*_args| nil }
    instance = klass.new(settings)
    drain_gtk
    expect(instance.objects.length).to eq(54)
    instance
  end

  # Two FIFO barriers include work enqueued by the initial queue block itself.
  def drain_gtk
    2.times do
      completed = Queue.new
      gtk.queue { completed << true }
      completed.pop(timeout: 2)
    end
  end

  def saved_settings_path = File.join(@settings_directory, 'GS', 'Fixture', 'ecleanse.yaml')

  it 'loads unchanged ecleanse XML and preserves original initialization, changes and Close saving' do
    settings = { stop_scripts: 'bigshot', cleanse_disease: true, cleanse_poison: false }
    form = original_ecleanse(settings)
    expect(Digest::SHA256.hexdigest(form.class.ui)).to eq('1dec1310d30d6b3f1e34beb7a39aeccdffdd6da70e87c476818759405be13eea')
    expect(form['stop_scripts'].text).to eq('bigshot')
    expect(form['stop_scripts'].send(:component_props)).to include(min_width_chars: 59)
    expect(form['cleanse_disease'].send(:component_props)).to include(disabled: true, checked: false)
    expect(settings[:cleanse_disease]).to be(false)
    gtk.queue do
      form['cleanse_poison'].active = true
      form['use_stance1'].active = true
    end
    drain_gtk
    gtk.queue { form['use_flee'].active = true }
    drain_gtk
    expect(settings).to include(cleanse_poison: true, use_flee: true, use_stance1: false)
    expect(form['use_stance1'].active?).to be(false)
    expect(File.exist?(saved_settings_path)).to be(false)
    close = form.objects.find { |object| object.instance_of?(gtk::Button) && object.label == 'Close' }
    gtk.queue { close.send(:emit_handlers, :activate) }
    drain_gtk
    expect(YAML.unsafe_load_file(saved_settings_path)).to include(cleanse_poison: true, use_flee: true)
    expect(form['main']).to be_destroyed
    expect(@messages.grep(/WITHOUT saving/)).to be_empty
    expect(Lich).to have_received(:log).with(/shadow-type=in accepted; inset decoration omitted/).once
  end

  %i[detach process_exit].each do |close_path|
    it "runs the original destroy callback without saving changed settings on #{close_path}" do
      settings = {}
      form = original_ecleanse(settings)
      form['main'].show_all
      page = nil
      Timeout.timeout(2) { sleep 0.001 until (page = service.registry.pages_for(owner).first)&.last_render }
      connection = double('connection', viewer_id: 'ecleanse-close', alive?: true, send_text: true)
      address = service.registry.address_for(page)
      service.runtime.handle(connection, type: 'attach', page: address)
      check = page.last_render.tree.each.find { |component| component.props[:label] == 'Cure Poison' }
      service.runtime.handle(connection, type: 'event', page: address, generation: page.generation,
                                         cid: check.cid, event: 'change', payload: { value: true })
      drain_gtk
      if close_path == :detach
        service.runtime.handle(connection, type: 'detach', page: address, generation: page.generation)
      else
        service.runtime.disconnect(connection)
        service.runtime.browser_closed(page)
      end
      drain_gtk
      expect(settings[:cleanse_poison]).to be(true)
      expect(File.exist?(saved_settings_path)).to be(false)
      expect(@messages.join).to include('WITHOUT saving')
      expect(form['main']).to be_destroyed
      expect(form.instance_variable_get(:@running)).to be(false)
    end
  end

  it 'uses shared character metrics and borderless frames without accepting Bigshot focus or alignment gaps' do
    load_xml('<object class="GtkLabel" id="label"><property name="width-chars">17</property></object><object class="GtkFrame" id="frame"><property name="shadow-type">none</property></object>')
    expect(builder['label'].send(:component_props)).to include(min_width_chars: 17)
    expect(builder['label'].send(:component_props)).not_to have_key(:width)
    expect(builder['frame'].send(:component_props)).to include(border_width: 0)
    [
      '<object class="GtkComboBoxText"><property name="has-entry">True</property><property name="can-focus">False</property></object>',
      '<object class="GtkComboBoxText"><property name="has-entry">True</property><child internal-child="entry"><object class="GtkEntry"><property name="can-focus">False</property></object></child></object>',
      '<object class="GtkLabel"><property name="can-focus">True</property></object>',
      '<object class="GtkCheckButton"><property name="valign">center</property></object>',
      '<object class="GtkCheckButton"><property name="draw-indicator">False</property></object>',
      '<object class="GtkCheckButton"><property name="receives-default">True</property></object>',
      '<object class="GtkButton"><property name="receives-default">False</property></object>',
      '<object class="GtkScrolledWindow"><property name="shadow-type">out</property></object>',
      '<object class="GtkEntry"><property name="can-focus">True</property><property name="editable">False</property></object>',
      '<object class="GtkEntry"><property name="editable">False</property><property name="can-focus">True</property></object>',
    ].each { |xml| expect { load_xml(xml) }.to raise_error(gtk::BuilderError) }
    expect(builder.objects.length).to eq(2)
  end

  it 'preserves object identity, literal text and subclass handler resolution' do
    derived = Class.new(gtk::Builder) do
      attr_reader :clicked

      def save
        @clicked = self['entry'].text
      end
    end.new
    derived.add_from_string(<<~XML)
      <interface><requires lib="gtk+" version="3.20"/>
        <object class="GtkWindow" id="main"><child><object class="GtkBox">
          <property name="orientation">vertical</property>
          <child><object class="GtkEntry" id="entry"><property name="text">001 True &amp; False</property></object></child>
          <child><object class="GtkButton" id="save"><property name="label">Save</property><signal name="clicked" handler="save" swapped="no"/></object></child>
        </object></child></object>
      </interface>
    XML
    expect(derived.get_object(:entry)).to equal(derived['entry'])
    expect(derived['entry'].builder_name).to eq('entry')
    expect(derived.objects.size).to eq(4)
    expect(derived.objects.map(&:builder_name)).to all(be_a(String))
    derived.objects.clear
    expect(derived.objects.size).to eq(4)
    expect(derived['missing']).to be_nil
    derived.connect_signals { |handler| derived.method(handler) }
    derived['save'].send(:emit_handlers, :activate)
    expect(derived.clicked).to eq('001 True & False')
    expect(service.registry.pages_for(owner)).to be_empty
  end

  it 'resolves forward model, adjustment and buffer references with typed values' do
    load_xml(<<~XML)
      <object class="GtkComboBox" id="combo"><property name="model">choices</property><property name="active">0</property>
        <child><object class="GtkCellRendererText"/><attributes><attribute name="text">1</attribute></attributes></child>
      </object>
      <object class="GtkSpinButton" id="spin"><property name="adjustment">range</property><property name="digits">1</property></object>
      <object class="GtkTextView" id="text"><property name="buffer">buffer</property></object>
      <object class="GtkListStore" id="choices"><columns><column type="gint"/><column type="gchararray"/></columns><data><row><col id="0">3</col><col id="1">001</col></row></data></object>
      <object class="GtkAdjustment" id="range"><property name="upper">10</property><property name="step-increment">0.5</property><property name="value">2.5</property></object>
      <object class="GtkTextBuffer" id="buffer"><property name="text">True</property></object>
    XML
    expect(builder['combo'].active_text).to eq('001')
    expect(builder['spin'].value).to eq(2.5)
    expect(builder['text'].buffer).to equal(builder['buffer'])
    expect(builder['buffer'].text).to eq('True')
  end

  it 'assembles notebook tabs and grid packing while retaining italic label presentation' do
    load_xml(<<~XML)
      <object class="GtkNotebook" id="tabs">
        <child><object class="GtkGrid" id="grid"><child><object class="GtkEntry" id="entry"/>
          <packing><property name="left-attach">1</property><property name="top-attach">2</property><property name="width">2</property></packing>
        </child></object></child>
        <child type="tab"><object class="GtkLabel" id="caption"><property name="label">Settings</property></object></child>
      </object>
      <object class="GtkLabel" id="notice"><property name="label">Save with Close</property><attributes><attribute name="style" value="italic"/></attributes></object>
    XML
    expect(builder['tabs'].children).to eq([builder['grid']])
    expect(builder['tabs'].send(:component_props)[:names]).to eq(['Settings'])
    expect(builder['entry'].instance_variable_get(:@placement)).to include(column: 2, row: 3, span: 2)
    expect(builder['notice'].send(:component_props)[:font_style]).to eq('italic')
  end

  it 'reuses the real TreeSelection and applies renderer bindings and false properties' do
    load_xml(<<~XML)
      <object class="GtkTreeView" id="view"><property name="model">store</property>
        <child internal-child="selection"><object class="GtkTreeSelection" id="selection"><property name="mode">multiple</property></object></child>
        <child><object class="GtkTreeViewColumn" id="column"><property name="title">Enabled</property>
          <child><object class="GtkCellRendererToggle" id="toggle"><property name="activatable">False</property></object><attributes><attribute name="active">0</attribute></attributes></child>
        </object></child>
      </object>
      <object class="GtkListStore" id="store"><columns><column type="gboolean"/></columns><data><row><col id="0">True</col></row></data></object>
    XML
    expect(builder['selection']).to equal(builder['view'].selection)
    expect(builder['selection'].mode).to eq(:multiple)
    expect(builder['toggle'].activatable?).to be(false)
    expect(builder['view'].send(:component_props)[:rows].first[:cells].values).to eq([true])
  end

  it 'rejects additions atomically with object, property and owner attribution' do
    load_xml('<object class="GtkEntry" id="retained"><property name="text">Keep</property></object>')
    original = builder.objects
    expect do
      load_xml('<object class="GtkWindow" id="candidate"><child><object class="GtkLabel" id="bad"><property name="angle">90</property></object></child></object>')
    end.to raise_error(gtk::BuilderError, /script=builder.lic.*object=bad.*property=angle.*unsupported property/)
    expect(builder.objects).to eq(original)
    expect(builder['retained'].text).to eq('Keep')
    expect(builder['candidate']).to be_nil
    expect(gtk.session.instance_variable_get(:@windows)).to be_empty
    expect(service.registry.pages_for(owner)).to be_empty
    expect { load_xml('<object class="GtkEntry" id="retained"/>') }.to raise_error(gtk::BuilderError, /duplicate identifier/)
    expect { load_xml('<object class="GtkTreeView"><property name="model">missing</property></object>') }.to raise_error(gtk::BuilderError, /unresolved.*missing/)
    expect do
      load_xml('<object class="GtkWindow" id="candidate"><child><object class="GtkEntry"><property name="width-request">70000</property></object></child></object>')
    end.to raise_error(gtk::BuilderError, /component properties/)
    expect(gtk.session.instance_variable_get(:@windows)).to be_empty
    expect(builder.objects).to eq(original)
  end

  it 'retains all unmapped properties and keeps structural diagnostics in queued failures' do
    xml = '<interface><object class="GtkWindow" id="main"><property name="decorated">False</property><property name="modal">True</property></object></interface>'
    expect { builder.add_from_string(xml) }.to raise_error(gtk::BuilderError) { |error| expect(error.issues.map { |issue| issue[:property] }).to eq(%w[decorated modal]) }
    messages = Queue.new
    allow(Lich).to receive(:log) { |message| messages << message if message.include?('blockers=') }
    gtk.queue { builder.add_from_string(xml) }
    message = messages.pop(timeout: 2)
    expect(message).to include('object=main', 'property=decorated', 'reason=unsupported property', 'blockers=2')
    expect(message).not_to include('<interface>', '>False<')
  end

  it 'loads local files and exposes the actual internal combo entry' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'form.ui')
      File.write(path, <<~XML)
        <interface><object class="GtkComboBoxText" id="combo"><property name="has-entry">True</property>
          <child internal-child="entry"><object class="GtkEntry" id="entry"><property name="text">Custom</property></object></child>
          <items><item>First</item><item>Second</item></items>
        </object></interface>
      XML
      builder.add_from_file(path)
      expect(builder['entry']).to equal(builder['combo'].child)
      expect(builder['combo'].active_text).to eq('Custom')
    end
  end

  it 'runs unchanged ecleanse setup through Chrome with the original callbacks', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    settings = { stop_scripts: 'bigshot', cleanse_poison: false }
    form = original_ecleanse(settings)
    form['main'].show_all
    page = nil
    Timeout.timeout(2) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-builder')
    drain_gtk
    expect(settings).to include(stop_scripts: 'hunting, travel', cleanse_poison: true, use_flee: true, use_stance1: false)
    expect(YAML.unsafe_load_file(saved_settings_path)).to include(stop_scripts: 'hunting, travel', cleanse_poison: true)
    expect(form['main']).to be_destroyed
    expect(@messages.grep(/WITHOUT saving/)).to be_empty
  end

  it 'validates every handler before connecting and preserves close veto return values' do
    load_xml(<<~XML)
      <object class="GtkWindow" id="main"><signal name="delete-event" handler="veto"/></object>
      <object class="GtkButton" id="button"><signal name="clicked" handler="save"/></object>
    XML
    calls = []
    expect { builder.connect_signals { |name| name == 'veto' ? proc { true } : nil } }.to raise_error(gtk::BuilderError, /handler must/)
    builder['button'].send(:emit_handlers, :activate)
    expect(calls).to be_empty
    builder.connect_signals { |name| name == 'veto' ? proc { true } : proc { calls << :saved } }
    builder.connect_signals { raise 'already connected' }
    expect(builder['main'].send(:emit_handlers, :close)).to be(true)
    builder['button'].send(:emit_handlers, :activate)
    expect(calls).to eq([:saved])
  end

  it 'refuses unknown structure, unsupported signal flags and unsafe or oversized XML' do
    [
      '<object class="GtkMissing" id="bad"/>',
      '<object class="GtkButton" id="bad"><signal name="clicked" handler="save" after="true"/></object>',
      '<object class="GtkLabel" id="bad"><style><class name="unknown"/></style></object>',
      '<object class="GtkEntry" id="bad"><property name="editable">not-a-boolean</property></object>',
      '<object class="GtkBox"><child><object class="GtkEntry"/><placeholder/></child></object>',
      '<object class="GtkFrame"><child type="label"><object class="GtkLabel"/><packing><property name="expand">True</property></packing></child></object>',
      '<object class="GtkComboBoxText"><property name="has-entry">True</property><child internal-child="entry"><object class="GtkEntry"><signal name="activate" handler="save"/></object></child></object>',
      '<object class="GtkNotebook"><child><object class="GtkBox"/></child><child type="tab"><object class="GtkLabel"><attributes><attribute name="style" value="italic"/></attributes></object></child></object>',
      '<object class="GtkTreeViewColumn"><child><object class="GtkCellRendererText"/><attributes><attribute name="text">0</attribute><attribute name="text">1</attribute></attributes></child></object>',
    ].each do |body|
      expect { load_xml(body) }.to raise_error(gtk::BuilderError)
      expect(builder.objects).to be_empty
    end
    expect { builder.add_from_string('<!DOCTYPE interface><interface/>') }.to raise_error(gtk::BuilderError, /DTD/)
    expect { builder.add_from_string('x' * (gtk::Builder::MAX_BYTES + 1)) }.to raise_error(gtk::BuilderError, /bounded/)
    expect { builder.add_from_string('<interface>') }.to raise_error(gtk::BuilderError, /malformed/)
  end
end
