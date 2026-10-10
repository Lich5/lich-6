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

  # Original list callbacks rely on Lich's real nil extension (uniq!.sort!).
  # Exercise that production environment without contaminating the parent suite
  # or replacing source callbacks. Each browser case still runs independently.
  def production_nil_example(example)
    return false if ENV['WEBUI_PRODUCTION_NIL'] == '1'

    extension = File.expand_path('../../../lib/common/class_exts/nilclass.rb', __dir__)
    output, status = Open3.capture2e(
      { 'WEBUI_PRODUCTION_NIL' => '1' }, RbConfig.ruby, '-S', 'rspec', '--require', extension, example.id
    )
    expect(status.success?).to be(true), output
    expect(output).to match(/1 example, 0 failures(?:\n|\r)/), output
    true
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

  # The original setup class runs unchanged. Game catalogs and persistence are
  # isolated here; no callback or widget logic is replaced to make a test pass.
  def original_e_setup(name, settings = {}, source_failure: false)
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:XMLData, double(game: 'GS'))
    sandbox.const_set(:Char, double(name: 'Fixture', prof: 'Ranger'))
    sandbox.const_set(:Stats, double(prof: 'Ranger'))
    sandbox.const_set(:Skills, double(slblessings: 20))
    sandbox.const_set(:Society, double(status: 'Council of Light', rank: 20))
    spells = Object.new
    spells.define_singleton_method(:[]) { |_id| Struct.new(:known?).new(false) }
    sandbox.const_set(:Spell, spells)
    town = "the town of Wehnimer's Landing"
    sandbox.const_set(:Map, double(list: [double(tags: ['publiclockers', 'ranger alchemy administrator'], location: town, find_nearest_by_tag: 1)]))
    sandbox.const_set(:Room, double(:rooms, :[] => double(location: town)))
    sandbox.const_set(:UserVars, double(mapdb_fwi_trinket: false))
    path = File.expand_path("../../fixtures/webui/#{name}_setup.lic", __dir__)
    sandbox.module_eval(File.read(path), path)
    mod = sandbox.const_get({ 'eloot' => :ELoot, 'ebounty' => :EBounty, 'eherbs' => :EHerbs, 'blackarts' => :BlackArts }.fetch(name))
    mod.define_singleton_method(:get_script_version) { 'fixture' }
    mod.define_singleton_method(:data) { Struct.new(:settings).new(settings) }
    destination = File.join(@settings_directory, "#{name}.yaml")
    mod.define_singleton_method(:save_profile) { |values = settings| File.write(destination, YAML.dump(values)) }
    # eherbs commits into script data; the outer game command owns disk saving.
    @eherbs_loaded = []
    loaded = @eherbs_loaded
    mod.define_singleton_method(:load) { |values| loaded << values.dup }
    klass = mod.const_get(:Setup)
    klass.define_method(:respond) { |*_args| nil }
    klass.define_method(:wait_while) { |&block| sleep 0.005 while block.call }
    # Profile discovery is a game-data lookup; avoid touching real character data.
    allow(Dir).to receive(:children).and_call_original
    allow(Dir).to receive(:children).with(/bigshot_profiles\z/).and_return(%w[fixture.yaml travel.yaml])
    allow(Dir).to receive(:foreach).and_call_original
    allow(Dir).to receive(:foreach).with(/bigshot_profiles\z/).and_yield('fixture.yaml').and_yield('travel.yaml')
    @setup_diagnostics = []
    allow(Lich).to receive(:log) { |message| @setup_diagnostics << message }
    form = klass.new(settings)
    2.times { drain_gtk }
    failures = @setup_diagnostics.grep(/callback failed/)
    if source_failure
      expect(failures.length).to eq(1), @setup_diagnostics.join("\n")
      expect(failures.first).to include('BuilderError', 'object=exclusions_label', 'property=get_object', 'undeclared object identifier')
    else
      expect(failures).to eq([]), @setup_diagnostics.join("\n")
    end
    expect(form.objects.length).to eq({ 'eloot' => 469, 'ebounty' => 435, 'eherbs' => 31, 'blackarts' => 216 }.fetch(name))
    form
  end

  %w[ebounty eherbs blackarts].each do |name|
    it "loads and publishes the unchanged #{name} setup with original callbacks" do |example|
      next if name != 'eherbs' && production_nil_example(example)

      settings = {}
      form = original_e_setup(name, settings)
      if name == 'eherbs'
        form['herb_container'].text = 'herb sack'
        form.on_update(form['herb_container'])
        drain_gtk
        expect(settings[:herb_container]).to eq('herb sack')
      elsif name == 'blackarts'
        form['guild_pause'].text = '25'
        form.on_update(form['guild_pause'])
        drain_gtk
        expect(settings[:guild_pause]).to eq('25')
      else
        key = 'culling_max'
        form[key].value = 25
        drain_gtk
        expect(settings[key.to_sym].to_f).to eq(25)
      end
      form['main'].show_all
      page = nil
      Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
      expect(page.last_render.tree.each.count).to be > 10
      form.on_close_clicked
      drain_gtk
      expect(form['main']).to be_destroyed
      expect(@setup_diagnostics.grep(/callback failed/)).to eq([]), @setup_diagnostics.join("\n")
      if name == 'eherbs'
        expect(@eherbs_loaded.last).to include(herb_container: 'herb sack')
      else
        expect(YAML.unsafe_load_file(File.join(@settings_directory, "#{name}.yaml"))).to eq(settings)
      end
    end
  end

  it 'refuses the original eloot missing tooltip target with a conversion diagnostic' do |example|
    next if production_nil_example(example)

    form = original_e_setup('eloot', {}, source_failure: true)
    expect { form['exclusions_label'] }.to raise_error(gtk::BuilderError, /object=exclusions_label.*native WebUI/)
    expect { form.set_tooltips }.to raise_error(gtk::BuilderError, /object=exclusions_label/)
    # The original initialization never reaches connect_signals after this error.
    expect(form['main'].instance_variable_get(:@destroy_handlers)).to be_nil
    expect(form['sell_locksmith_pool'].sensitive?).to be(true)
    expect(form['locksmith_priority'].sensitive?).to be(false)
  end

  %w[ebounty eherbs blackarts].each do |name|
    it "validates #{name} original interactions and layout in Chrome", browser: true do |example|
      skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
      next if name != 'eherbs' && production_nil_example(example)

      settings = {}
      form = original_e_setup(name, settings)
      form['main'].show_all
      page = nil
      Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
      # Private handles are inspected only by this test harness, avoiding any
      # production script-name IDs or changes to original setup declarations.
      controls = form.objects.filter_map do |widget|
        handle = widget.instance_variable_get(:@handle)
        next unless handle && widget.respond_to?(:builder_name)
        [widget.builder_name, widget.session.port.send(:node!, handle).cid]
      end.to_h
      WebUIBrowser.check(service: service, page: page, scenario: "shim-#{name}", controls: controls)
      drain_gtk
      expect(form['main']).to be_destroyed
      expect(@setup_diagnostics.grep(/callback failed/)).to eq([]), @setup_diagnostics.join("\n")
      if name == 'ebounty'
        expect(settings).to include(culling_max: 25, selling_script: 'fixture-sell', once_and_done: false, new_bounty_on_exit: false)
        expect(settings[:creature_exclude]).to eq([])
        expect(YAML.unsafe_load_file(File.join(@settings_directory, "#{name}.yaml"))).to eq(settings)
      elsif name == 'eherbs'
        expect(@eherbs_loaded.last).to include(herb_container: 'herb sack', buy_missing: true)
      else
        expect(settings).to include(guild_pause: '25', profile_a: 'travel', home_guild: "Wehnimer's Landing")
        expect(settings[:item_include]).to eq(form.instance_variable_get(:@default_buy))
        expect(settings[:consignment_include]).to eq(form.instance_variable_get(:@default_sell))
        expect(YAML.unsafe_load_file(File.join(@settings_directory, "#{name}.yaml"))).to eq(settings)
      end
    end
  end

  # Preserve the original setup and its handlers; only game services and the save
  # destination are substituted. This is not an execution of the casting loop.
  def original_ewaggle
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:Gdk, scope.const_get(:Gdk))
    sandbox.const_set(:Script, Lich::Common::Script)
    spells = [Struct.new(:num, :name, :time_per).new(101, 'Spirit Warding I', 1), Struct.new(:num, :name, :time_per).new(102, 'Spirit Barrier', 1)]
    spells.each { |spell| spell.define_singleton_method(:known?) { true } }
    catalog = Object.new
    catalog.define_singleton_method(:list) { spells }
    catalog.define_singleton_method(:[]) { |number| spells.find { |spell| spell.num == number } || Struct.new(:known?).new(number != 511) }
    sandbox.const_set(:Spell, catalog)
    sandbox.const_set(:Armor, double(known?: false))
    sandbox.const_set(:Society, double(member: 'Council of Light', rank: 20))
    @messages = []
    messages = @messages
    messaging = Module.new
    messaging.define_singleton_method(:msg) { |_type, message| messages << message }
    stub_const('Lich::Messaging', messaging)
    path = File.expand_path('../../fixtures/webui/ewaggle_setup.lic', __dir__)
    sandbox.module_eval(File.read(path), path)
    mod = sandbox.const_get(:Ewaggle)
    @ewaggle_settings = { cast_list: ['101  Spirit Warding I'], sonic_armor: 'Robes' }
    settings, destination = @ewaggle_settings, File.join(@settings_directory, 'ewaggle.yaml')
    mod.define_singleton_method(:get_script_version) { 'fixture' }
    mod.define_singleton_method(:armor_spells) { {} }
    mod.define_singleton_method(:data) { Struct.new(:settings).new(settings) }
    mod.define_singleton_method(:save_profile) { File.write(destination, YAML.dump(settings)) }
    klass = mod.const_get(:Setup)
    klass.define_method(:respond) { |*_args| nil }
    klass.define_method(:wait_while) { |&block| sleep 0.005 while block.call }
    form = klass.new(settings)
    drain_gtk
    expect(form['main']).to be_a(gtk::Window)
    expect(form['cast_list_store'].size).to eq(1)
    form
  end

  it 'loads the original ewaggle setup, named choices and numeric callbacks without source edits' do
    form = original_ewaggle
    expect(Digest::SHA256.hexdigest(form.class.ewaggle_ui)).to eq('c617157ee342adb4bfcb9d3281de5d63c17ef777d4f75fcad60544ec6049eddf')
    expect(form['sonic_armor'].active_id).to eq('Robes')
    expect(form['sonic_armor'].set_active_id('Full Plate')).to be(true)
    expect(@ewaggle_settings[:sonic_armor]).to eq('Full Plate')
    expect(form['sonic_armor'].set_active_id('missing')).to be(false)
    expect(form['sonic_armor'].active_id).to eq('Full Plate')
    form['start_at'].value = 90
    expect(@ewaggle_settings[:start_at]).to eq(90)
    form['sonic_armor'].remove_all
    expect(form['sonic_armor'].active_id).to be_nil
    form['main'].destroy
    drain_gtk
    expect(File.exist?(File.join(@settings_directory, 'ewaggle.yaml'))).to be(false)
    expect(@messages.join).to include('WITHOUT saving')
  end

  it 'routes validated row drops through the original ewaggle callbacks without automatic model edits' do
    diagnostics = []
    allow(Lich).to receive(:log) { |message| diagnostics << message }
    form = original_ewaggle
    allow(gtk.session).to receive(:refuse).and_wrap_original do |method, receiver, operation|
      diagnostics << "#{receiver.class}: #{operation}"
      method.call(receiver, operation)
    end
    form['main'].show_all
    page = nil
    Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    sent = []
    connection = double('connection', viewer_id: 'ewaggle-drop', alive?: true)
    allow(connection).to receive(:send_text) { |message| sent << JSON.parse(message) }
    address = service.registry.address_for(page)
    service.runtime.handle(connection, type: 'attach', page: address)
    tables = page.last_render.tree.each.select { |component| component.type == :table }
    source = tables.find { |table| table.props[:rows].any? { |row| row[:cells].values.include?('102  Spirit Barrier') } }
    target = tables.find { |table| table != source }
    service.runtime.handle(connection, type: 'event', page: address, generation: page.generation,
                                       cid: target.cid, event: 'row_drop', payload: { source: source.cid, row: source.props[:rows].first[:key] })
    drain_gtk
    expect(form['cast_list_store'].rows.map { |row| row[0] }).to contain_exactly('101  Spirit Warding I', '102  Spirit Barrier'), diagnostics.join("\n")
    expect(form['not_to_cast_store'].size).to eq(0)
    expect(sent.select { |message| message['type'] == 'error' }).to be_empty
  end

  it 'refuses unsafe label markup and unimplemented transfer protocols without publishing a partial form' do
    [
      '<a href="javascript:alert(1)">bad</a>',
      '<a href="https://user:pass@example.org/">bad</a>',
      '<a href="https://example.org/" onclick="bad()">bad</a>',
      '<a href="https://example.org/"><b>nested</b></a>',
    ].each do |text|
      expect do
        load_xml("<object class=\"GtkLabel\"><property name=\"label\">#{CGI.escapeHTML(text)}</property><property name=\"use-markup\">True</property></object>")
      end.to raise_error(gtk::BuilderError)
      expect(builder.objects).to be_empty
    end
    expect { gtk::TargetEntry.new('text/uri-list', gtk::TargetFlags::SAME_APP, 0) }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::DragContext.new.finish(success: true, delete: true, time: 0) }.to raise_error(gtk::UnsupportedOperation)
    combo = gtk::ComboBoxText.new
    combo.append('one', 'Duplicate label')
    combo.append('two', 'Duplicate label')
    expect { combo.append('one', 'new') }.to raise_error(gtk::UnsupportedOperation)
    expect(combo.model.size).to eq(2)
    combo.set_active_id('two')
    expect(combo.active).to eq(1)
    spin = gtk::SpinButton.new(0, 100, 1)
    spin.text = '0'
    spin.text = '10'
    expect(spin.value).to eq(10)
    expect { spin.text = 'not a number' }.to raise_error(gtk::UnsupportedOperation)
  end

  it 'preserves ewaggle search, transfers, choice edits and original save callbacks in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    form = original_ewaggle
    runner = Thread.new { form.start }
    page = nil
    Timeout.timeout(3) { sleep 0.005 until (page = service.registry.pages_for(owner).first)&.last_render }
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-ewaggle')
    drain_gtk
    runner.join(2)
    saved = YAML.unsafe_load_file(File.join(@settings_directory, 'ewaggle.yaml'))
    expect(saved).to include(sonic_armor: 'Full Plate', start_at: 90)
    expect(saved[:cast_list]).to contain_exactly('101  Spirit Warding I', '102  Spirit Barrier', '102  Spirit Barrier')
    expect(saved[:not_to_cast]).to be_empty
    expect(form['main']).to be_destroyed
  ensure
    form&.[]('main')&.destroy
    runner&.join(2)
  end

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

  it 'uses shared character metrics and borderless frames while refusing unsupported focus and alignment values' do
    load_xml('<object class="GtkLabel" id="label"><property name="width-chars">17</property></object><object class="GtkFrame" id="frame"><property name="shadow-type">none</property></object>')
    expect(builder['label'].send(:component_props)).to include(min_width_chars: 17)
    expect(builder['label'].send(:component_props)).not_to have_key(:width)
    expect(builder['frame'].send(:component_props)).to include(border_width: 0)
    [
      '<object class="GtkComboBoxText"><property name="has-entry">True</property><property name="can-focus">True</property></object>',
      '<object class="GtkLabel"><property name="can-focus">True</property></object>',
      '<object class="GtkCheckButton"><property name="valign">baseline</property></object>',
      '<object class="GtkCheckButton"><property name="draw-indicator">False</property></object>',
      '<object class="GtkCheckButton"><property name="receives-default">invalid</property></object>',
      '<object class="GtkButton"><property name="receives-default">False</property></object>',
      '<object class="GtkScrolledWindow"><property name="shadow-type">out</property></object>',
      '<object class="GtkEntry"><property name="can-focus">True</property><property name="editable">False</property></object>',
      '<object class="GtkEntry"><property name="editable">False</property><property name="can-focus">True</property></object>',
    ].each { |xml| expect { load_xml(xml) }.to raise_error(gtk::BuilderError) }
    expect(builder.objects.length).to eq(2)
  end

  it 'keeps label content alignment, padding and margins independent of declaration order' do
    load_xml(<<~XML)
      <object class="GtkGrid" id="grid"><property name="row-homogeneous">True</property>
        <child><object class="GtkLabel" id="caption">
          <property name="yalign">0</property><property name="xalign">1</property>
          <property name="xpad">5</property><property name="ypad">3</property>
          <property name="margin-start">9</property><property name="angle">90</property>
          <property name="valign">center</property>
          <attributes><attribute name="foreground" value="#ffff00000000"/></attributes>
        </object></child>
      </object>
    XML
    expect(builder['grid'].send(:component_props)).to include(equal_rows: true)
    expect(builder['caption'].send(:component_props)).to include(
      align: :end, content_vertical_align: :start, vertical_align: :center,
      padding_x: 5, padding_y: 3, rotation: '90', margin: { left: 9 }, foreground: { r: 255, g: 0, b: 0, a: 1.0 }
    )
    expect { builder['caption'].angle = 45 }.to raise_error(gtk::UnsupportedOperation)
    expect { builder['caption'].set_padding(-1, 3) }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::TextView.new.accepts_tab = true }.to raise_error(gtk::UnsupportedOperation)
    validator = Lich::WebUI::Validator.new
    expect { validator.validate_component!(:grid, { cols: 2, equal_rows: true, row_sizing: :spread }, owner: owner.name, page_id: nil, cid: nil) }.to raise_error(Lich::WebUI::SchemaViolationError)
  end

  it 'reuses one closed select for a noneditable combo entry and one numeric change stream' do
    load_xml(<<~XML)
      <object class="GtkComboBoxText" id="choice"><property name="has-entry">True</property>
        <property name="can-focus">False</property>
        <child internal-child="entry"><object class="GtkEntry" id="entry">
          <property name="editable">False</property><property name="can-focus">True</property>
          <property name="width-chars">12</property>
        </object></child><items><item>First</item></items>
      </object>
    XML
    expect(builder['choice'].send(:component_props)).to include(editable: false, min_width_chars: 12)
    builder['entry'].text = 'First'
    expect(builder['choice'].active_text).to eq('First')
    expect { builder['entry'].text = 'Unknown' }.to raise_error(gtk::UnsupportedOperation)
    spin = gtk::SpinButton.new(0, 100, 1)
    events = []
    spin.signal_connect('changed') { events << [:text, spin.buffer.text] }
    spin.signal_connect('value_changed') { events << [:value, spin.value] }
    spin.value = 15
    expect(events).to eq([[:text, '15'], [:value, 15]])
    expect { spin.buffer.text = '18' }.to raise_error(gtk::UnsupportedOperation)
  end

  it 'keeps combo entry focus on one shared input and maps button requests to minima' do
    load_xml(<<~XML)
      <object class="GtkComboBoxText" id="choice"><property name="has-entry">True</property>
        <child internal-child="entry"><object class="GtkEntry" id="entry">
          <property name="can-focus">False</property>
        </object></child><items><item>First</item></items>
      </object>
      <object class="GtkButton" id="action"><property name="label">Action</property>
        <property name="height-request">40</property><property name="width-request">80</property>
      </object>
    XML
    builder['entry'].text = 'Custom'
    expect(builder['choice'].active_text).to eq('Custom')
    expect(builder['choice'].send(:component_props)).to include(editable: true)
    expect(builder['action'].send(:component_props)).to include(min_height: 40, min_width: 80)
    expect(builder['action'].send(:component_props)).not_to have_key(:height)
    expect(builder['action'].send(:component_props)).not_to have_key(:width)
    expect(Lich).to have_received(:log).with(/internal combo entry focus hint is ignored/).once
    expect { builder['entry'].can_focus = :invalid }.to raise_error(gtk::UnsupportedOperation)
  end

  it 'reports ignored modality without limiting same-owner or other-owner windows' do
    first = gtk::Window.new
    first.modal = true
    second = gtk::Window.new
    [first, second].each(&:show_all)
    other = Struct.new(:name).new('other-setup.lic')
    allow(Lich::Common::Script).to receive(:current).and_return(other)
    third = gtk::Window.new
    third.modal = true
    third.show_all
    Timeout.timeout(3) { sleep 0.005 until service.registry.descriptors.length == 3 }
    expect(service.registry.pages_for(owner).length).to eq(2)
    expect(service.registry.pages_for(other).length).to eq(1)
    expect(service.registry.descriptors).to all(satisfy { |descriptor| !descriptor.key?(:modal_for) })
  ensure
    Lich::Common::ScriptDeath.run(other) if other
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
    derived.connect_signals { |handler| derived.method(handler) }
    derived['save'].send(:emit_handlers, :activate)
    expect(derived.clicked).to eq('001 True & False')
    expect(service.registry.pages_for(owner)).to be_empty
  end

  it 'refuses undeclared IDs through both lookup APIs without damaging loaded objects' do
    load_xml('<object class="GtkEntry" id="retained"><property name="text">Keep</property></object>')
    original = builder['retained']
    %i[get_object []].each do |lookup|
      expect { builder.public_send(lookup, :missing) }.to raise_error(gtk::BuilderError) do |error|
        expect(error.message).to match(/script=builder.lic.*object=missing.*property=get_object.*native WebUI/)
        expect(error.issues.first).to include(object: 'missing', property: 'get_object')
        expect(error.diagnostic).to include('object=missing', 'property=get_object', 'blockers=1')
      end
    end
    expect(builder.get_object(:retained)).to equal(original)
    expect(original.text).to eq('Keep')
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
      load_xml('<object class="GtkWindow" id="candidate"><child><object class="GtkLabel" id="bad"><property name="angle">45</property></object></child></object>')
    end.to raise_error(gtk::BuilderError, /script=builder.lic.*object=bad.*property=angle/)
    expect(builder.objects).to eq(original)
    expect(builder['retained'].text).to eq('Keep')
    expect { builder['candidate'] }.to raise_error(gtk::BuilderError, /object=candidate/)
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
    xml = '<interface><object class="GtkWindow" id="main"><property name="decorated">False</property><property name="transient-for">peer</property></object></interface>'
    expect { builder.add_from_string(xml) }.to raise_error(gtk::BuilderError) { |error| expect(error.issues.map { |issue| issue[:property] }).to eq(%w[decorated transient-for]) }
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
