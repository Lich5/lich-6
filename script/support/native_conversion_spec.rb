# frozen_string_literal: true

# Explicit source acceptance tests for the separate, authorized scripts repo.
# Game, persistence and browser launch effects are fixtures; UI controllers are
# read directly from their production .lic files, not copied into this harness.
require_relative '../../spec/spec_helper'
require 'webui'
require 'yaml'
require 'timeout'

RSpec.describe 'native script conversions' do
  let(:scripts_root) { ENV.fetch('NATIVE_SCRIPTS_ROOT') }

  before { |example| skip 'explicit browser acceptance run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1' }

  def browser_host(owner)
    host = @service || Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(host)
    allow(Lich::WebUI).to receive(:registry).and_return(host.registry)
    allow(Lich::WebUI).to receive(:start).and_call_original
    allow(Lich::WebUI).to receive(:open)
    worker = Thread.new { yield }
    page = Timeout.timeout(5) do
      loop do
        candidate = host.registry.pages_for(owner).first
        break candidate if candidate&.last_render
        worker.value unless worker.alive?
        sleep 0.01
      end
    end
    host.start
    puts "NATIVE_BROWSER_URL=#{host.launch_url(page: page)}"
    $stdout.flush
    expect(worker.join(180)).to equal(worker)
    worker.value
  ensure
    worker&.kill if worker&.alive?
    host&.stop
  end

  describe 'repository browser' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/repository.lic'))
      definitions = @source.split('# GUI implementation', 2).last.split('# File uploader', 2).first
      @scope = Module.new
      @scope.module_eval(definitions, 'repository.lic')
      @service = Lich::WebUI::Service.new
      allow(Lich::WebUI).to receive(:service).and_return(@service)
      allow(Lich::WebUI).to receive(:registry).and_return(@service.registry)
      allow(Lich::WebUI).to receive(:start)
      allow(Lich::WebUI).to receive(:open)
      @downloads = []
      @items = [['header'], ['alpha.lic', 'GS', '1024', '0', 'Fixture A', '12', '8', '2', 'combat', '<literal comments>'],
                ['beta.lic', 'DR', '2048', '100', 'Fixture B', '24', '0', '0', 'travel', 'Beta comments']]
      @gui = @scope::RepositoryGUI::Setup.new(@items, owner: :repository_fixture, download: proc { |item| @downloads << item })
      @gui.show
    end

    after { @service&.stop }

    def select_repository_row(key)
      render = @gui.page.last_render
      table = render.tree.each.find { |node| node.type == :table }
      render.bindings.fetch([table.cid, :selection_change]).call(Struct.new(:payload).new({ rows: [key] }))
    end

    it 'shows literal comments and binds Download to the exact selected row' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|<interface>/)
      select_repository_row('entry-0')
      render = @gui.page.last_render
      expect(render.tree.each.any? { |node| node.props[:content] == '<literal comments>' }).to be(true)
      button = render.tree.each.find { |node| node.props[:label] == 'Download alpha.lic' }
      expect(@downloads).to eq([])
      render.bindings.fetch([button.cid, :activate]).call(nil)
      expect(@downloads).to eq([@items[1]])
    end

    it 'filters all columns and clears the old download choice' do
      select_repository_row('entry-0')
      @gui.search('TRAVEL')
      tree = @gui.page.last_render.tree
      table = tree.each.find { |node| node.type == :table }
      expect(table.props[:rows].map { |row| row[:key] }).to eq(['entry-1'])
      expect(tree.each.any? { |node| node.props[:label].to_s.start_with?('Download ') }).to be(false)
      expect(@downloads).to eq([])
    end

    it 'browser searches, selects and downloads only a fixture row', browser: true do
      browser_host(:repository_fixture) { @gui.wait }
      expect(@downloads).to eq([@items[2]])
    end
  end

  describe 'soundfx manager' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/soundfx.lic')).gsub("\r\n", "\n")
      definitions = @source[/  class Manager\n.*?(?=  def self.build_gui)/m]
      expect(definitions).not_to be_nil, 'native SoundFX manager is missing'
      @scope = Module.new
      @scope.module_eval(definitions, 'soundfx.lic')
      @service = Lich::WebUI::Service.new
      allow(Lich::WebUI).to receive(:service).and_return(@service)
      allow(Lich::WebUI).to receive(:registry).and_return(@service.registry)
      allow(Lich::WebUI).to receive(:start)
      allow(Lich::WebUI).to receive(:open)
      @saved = []
      @manager = @scope::Manager.new(owner: :sound_fixture, triggers: { 'warning' => 'bell' }, sounds: %w[bell gong],
                                     save: proc { |value| @saved << value })
      @manager.show
    end

    after { @service&.stop }

    def click(label, submitted = [])
      render = @manager.page.last_render
      button = render.tree.each.find { |node| node.props[:label] == label }
      scope = render.submissions.fetch(button.cid, [])
      submission = Lich::WebUI::Submission.new(viewer_id: 'fixture', values: scope.zip(submitted).to_h)
      render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
    end

    it 'edits, adds and marks rows for removal before one explicit Save' do
      expect(@source).not_to match(/Gtk::|Gtk\.|GLib::|require ['"]gtk3/)
      click('Add Trigger')
      expect(@saved).to eq([])
      click('Save Changes', ['warning', 'bell', true, 'new notice', 'gong', false])
      expect(@saved).to eq([{ 'new notice' => 'gong' }])
      expect(@service.registry.pages_for(:sound_fixture)).to be_empty
    end

    it 'rejects empty or duplicate triggers and permits correction' do
      click('Save Changes', ['', 'bell', false])
      expect(@saved).to eq([])
      expect(@manager.page.last_render.tree.each.any? { |node| node.props[:content].to_s.include?('Trigger cannot be empty') }).to be(true)
      click('Add Trigger')
      click('Save Changes', ['warning', 'bell', false, 'WARNING', 'gong', false])
      expect(@saved).to eq([])
      click('Cancel')
      expect(@saved).to eq([])
    end

    it 'refuses oversized catalogs before opening a page rather than truncating settings' do
      expect { @scope::Manager.new(owner: :large, triggers: (1..257).to_h { |n| [n.to_s, 'bell'] }, sounds: ['bell'], save: proc {}) }.to raise_error(ArgumentError, /256/)
      expect { @scope::Manager.new(owner: :large, triggers: {}, sounds: (1..512).map(&:to_s), save: proc {}) }.to raise_error(ArgumentError, /510/)
      expect(@service.registry.pages_for(:large)).to be_empty
    end

    it 'browser edits and adds sound triggers before Save', browser: true do
      browser_host(:sound_fixture) do
        Timeout.timeout(180) { sleep 0.01 until @service.registry.pages_for(:sound_fixture).empty? }
      end
      expect(@saved).to eq([{ 'new notice' => 'gong' }])
    end
  end

  describe 'bardwag setup' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/bardwag.lic'))
      @scope = Module.new
      @settings = { 'cast_list' => [401, 101] }
      spell = Struct.new(:num, :name, :time_per)
      @spells = { 101 => spell.new(101, 'Spirit Warding I', 10), 401 => spell.new(401, 'Elemental Defense I', 10) }
      @scope.const_set(:CharSettings, @settings)
      @scope.const_set(:Spell, @spells)
      @scope.const_set(:Spells, Struct.new(:known).new(@spells.values))
      @script = Struct.new(:vars, :name).new(['setup', 'setup'], 'bardwag')
      script = @script
      @scope.define_singleton_method(:script) { script }
    end

    def run_setup
      @scope.module_eval(@source, 'bardwag.lic')
    rescue SystemExit
      nil
    end

    it 'runs the actual setup entrypoint without GTK and preserves Cancel' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|Gdk::|HAVE_GTK/)
      allow(Lich::WebUI::SettingsForm).to receive(:edit).and_return(nil)
      run_setup
      expect(@settings).to eq('cast_list' => [401, 101])
    end

    it 'saves a validated order and rejects unknown spell numbers without losing settings' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:values][:cast_order]).to eq("401\n101")
        expect { options[:normalize].call(options[:values].merge(cast_order: '999999')) }.to raise_error(ArgumentError, /known/)
        options[:normalize].call(options[:values].merge(cast_order: "101\n401", sonic_weapon: 'rapier', retribution_spell: 'off'))
      end
      run_setup
      expect(@settings).to include('cast_list' => [101, 401], 'sonic_weapon' => 'rapier', 'retribution_spell' => nil)
      expect(@settings).not_to have_key('cast_order')
    end

    it 'browser edits bardwag cast order and saves sonic settings', browser: true do
      browser_host(@script) { run_setup }
      expect(@settings).to include('cast_list' => [101, 401], 'sonic_weapon' => 'rapier')
    end
  end

  describe 'eherbs setup' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/eherbs.lic'))
      definitions = @source.split('  # Native herb setup', 2).last.lines.drop(1).join.split('  def self.known_herbs', 2).first
      @scope = Module.new
      @scope.module_eval("module EHerbs\n#{definitions}\nend", 'eherbs.lic')
      @herbs = @scope.const_get(:EHerbs)
      @scope.const_set(:Script, Struct.new(:current).new(:fixture_owner))
      @scope.const_set(:Spell, Hash.new(Struct.new(:known?).new(false)))
      @scope.const_set(:Society, Struct.new(:status, :rank).new('None', 0))
    end

    it 'backfills nil setup values without mutating the caller on Cancel' do
      settings = { use_yaba: nil }
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:values][:use_yaba]).to eq(false)
        nil
      end
      @herbs::Setup.new(settings).start
      expect(settings).to eq(use_yaba: nil)
    end

    it 'preserves non-form metadata and returns no changes on Cancel' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|<interface>/)
      settings = { prices: { 'acantha' => 50 }, stock: 90 }
      allow(Lich::WebUI::SettingsForm).to receive(:edit).and_return(nil)
      expect(@herbs::Setup.new(settings).start).to be_nil
      expect(settings).to eq(prices: { 'acantha' => 50 }, stock: 90)
    end

    it 'validates stocking percentage and refuses unavailable healing abilities' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:fields].size).to eq(13)
        expect(options[:values][:stock]).to eq('90')
        expect { options[:normalize].call(options[:values].merge(stock: '120')) }.to raise_error(ArgumentError, /0.*100/)
        options[:normalize].call(options[:values].merge(stock: ' 75 ', use650: true, herb_container: '  satchel  '))
      end
      saved = @herbs::Setup.new(stock: 90, prices: { 'acantha' => 50 }).start
      expect(saved).to include(stock: '75', use650: false, herb_container: 'satchel', prices: { 'acantha' => 50 })
    end

    it 'browser corrects invalid herb stock before Save', browser: true do
      saved = browser_host(:fixture_owner) { @herbs::Setup.new(stock: 90).start }
      expect(saved).to include(stock: '75', herb_container: 'satchel')
    end
  end

  describe 'ewaggle setup' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/ewaggle.lic'))
      definitions = @source.split('# Setup', 2).last.split('# Profile loading/saving', 2).first
      @scope = Module.new
      @scope.module_eval(definitions, 'ewaggle.lic')
      @waggle = @scope.const_get(:Ewaggle)
      known = Struct.new(:num, :name, :time_per, :known?).new(101, 'Spirit Warding I', 10, true)
      spells = Hash.new(Struct.new(:known?).new(false))
      spells[101] = known
      spells.define_singleton_method(:list) { [known] }
      @scope.const_set(:Spell, spells)
      @scope.const_set(:Armor, double('unavailable ability', known?: false))
      @scope.const_set(:Society, Struct.new(:member, :rank).new('None', 0))
      @scope.const_set(:Script, Struct.new(:current).new(:fixture_owner))
      @settings = { cast_list: [], not_to_cast: ['101  Spirit Warding I'] }
      @waggle.define_singleton_method(:data) { @fixture_data }
      @waggle.instance_variable_set(:@fixture_data, Struct.new(:settings).new(@settings))
      @waggle.define_singleton_method(:get_script_version) { 'fixture' }
      @waggle.define_singleton_method(:armor_spells) { {} }
      @waggle.define_singleton_method(:save_profile) {}
      allow(@waggle).to receive(:save_profile)
    end

    it 'backfills nil setup values without mutating the caller on Cancel' do
      settings = { cast_list: nil }
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:values][:cast_list]).to eq([])
        nil
      end
      @waggle::Setup.new(settings).start
      expect(settings).to eq(cast_list: nil)
    end

    it 'uses native spell choices and leaves settings unchanged on Cancel' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|Gdk::|<interface>/)
      allow(Lich::WebUI::SettingsForm).to receive(:edit).and_return(nil)
      @waggle::Setup.new(@settings).start
      expect(@waggle).not_to have_received(:save_profile)
      expect(@settings[:cast_list]).to eq([])
    end

    it 'moves chosen known spells between lists and disables unavailable abilities' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:fields]).to include(hash_including(key: :cast_101, type: :checkbox, label: '101  Spirit Warding I'))
        expect(options[:fields].find { |field| field[:key] == :use_wracking }[:disabled]).to be(true)
        options[:normalize].call(options[:values].merge(cast_101: true, use_wracking: true))
      end
      @waggle::Setup.new(@settings).start
      expect(@settings[:cast_list]).to eq(['101  Spirit Warding I'])
      expect(@settings[:not_to_cast]).to eq([])
      expect(@settings[:use_wracking]).to be(false)
      expect(@settings).not_to have_key(:cast_101)
      expect(@waggle).to have_received(:save_profile).once
    end

    it 'browser chooses an ewaggle spell and saves', browser: true do
      browser_host(:fixture_owner) { @waggle::Setup.new(@settings).start }
      expect(@settings[:cast_list]).to eq(['101  Spirit Warding I'])
    end
  end

  describe 'ecleanse setup' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/ecleanse.lic'))
      definitions = @source.split('# UI Setup', 2).last.split('# Load/Save profiles', 2).first
      @scope = Module.new
      @scope.module_eval(definitions, 'ecleanse.lic')
      @cleanse = @scope.const_get(:Ecleanse)
      @scope.const_set(:Script, Struct.new(:current).new(:fixture_owner))
      @scope.const_set(:Spell, Hash.new(Struct.new(:known?).new(false)))
      @scope.const_set(:CMan, double('combat maneuvers', known?: false, stun_maneuvers: 0))
      @scope.const_set(:Feat, double('unavailable ability', known?: false))
      @cleanse.const_set(:Util, Class.new { def self.get_script_version = 'fixture' })
      @scope.const_set(:DATA_DIR, '/fixture')
      @scope.const_set(:XMLData, Struct.new(:game).new('GSF'))
      @scope.const_set(:Char, Struct.new(:name).new('Fixture'))
      allow(File).to receive(:write)
    end

    it 'backfills nil setup values without mutating the caller on Cancel' do
      settings = { stop_scripts: nil }
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:values][:stop_scripts]).to eq('')
        nil
      end
      @cleanse::Setup.new(settings).start
      expect(settings).to eq(stop_scripts: nil)
    end

    it 'removes Builder and does not save when cancelled' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|<interface>/)
      settings = { stop_scripts: 'bigshot', recover_disarmed: true }
      allow(Lich::WebUI::SettingsForm).to receive(:edit).and_return(nil)
      @cleanse::Setup.new(settings).start
      expect(File).not_to have_received(:write)
      expect(settings).to eq(stop_scripts: 'bigshot', recover_disarmed: true)
    end

    it 'keeps unavailable abilities disabled and normalizes one exclusive stun action' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:fields].find { |field| field[:key] == :cleanse_poison }[:disabled]).to be(true)
        expect(options[:fields].find { |field| field[:key] == :stun_action }[:options]).to eq([{ value: 'none', label: 'None' }])
        result = options[:normalize].call(options[:values].merge(cleanse_poison: true, stop_scripts: ' bigshot, eloot ', stun_action: 'none'))
        expect(result[:cleanse_poison]).to be(false)
        expect(result[:script_list]).to eq(%w[bigshot eloot go2])
        expect(result.values_at(:use_stance1, :use_stance2, :use_flee, :use_hide)).to eq([false] * 4)
        result
      end
      @cleanse::Setup.new({}).start
      expect(File).to have_received(:write).with('/fixture/GSF/Fixture/ecleanse.yaml', kind_of(String))
    end

    it 'browser saves ecleanse disarm preferences', browser: true do
      browser_host(:fixture_owner) { @cleanse::Setup.new({}).start }
      expect(File).to have_received(:write).with('/fixture/GSF/Fixture/ecleanse.yaml', a_string_including('bigshot', ':recover_disarmed: true'))
    end
  end

  describe 'go2 setup' do
    before do
      @source = File.read(File.join(scripts_root, 'scripts/go2.lic'))
      definitions = @source.split("  setting_value = ", 2).first
      @scope = Module.new
      @scope.module_eval(definitions + "\nend\n", 'go2.lic')
      @go2 = @scope.const_get(:Go2)
      @settings = {}
      allow(@go2).to receive(:load_go2_settings).and_return(@settings)
      allow(@go2).to receive(:get_script_version).and_return('fixture')
      allow(@go2).to receive(:save_go2_settings)
      @scope.const_set(:XMLData, Struct.new(:game).new('GSF'))
      @scope.const_set(:Stats, Struct.new(:prof).new('Rogue'))
      @scope.const_set(:Script, Struct.new(:current).new(:fixture_owner))
    end

    it 'defines native setup with no GTK fallback or Builder markup' do
      expect(@source).not_to match(/Gtk::|Gtk\.queue|<interface>/)
      expect(@go2).to respond_to(:setup)
    end

    it 'does not persist Cancel and keeps the caller settings unchanged' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit).and_return(nil)
      @go2.setup
      expect(@go2).not_to have_received(:save_go2_settings)
      expect(@settings).to eq({})
    end

    it 'offers all twenty-four GS controls with existing bounds and save normalization' do
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:fields].size).to eq(24)
        expect(options[:fields].find { |field| field[:key] == :delay }).to include(min: 0, max: 600)
        expect(options[:fields].find { |field| field[:key] == :mapdb_ice_mode }[:options].map { |item| item[:value] }).to eq(%w[auto wait run])
        options[:normalize].call(options[:values].merge(mapdb_fwi_trinket: '  bracelet  ', delay: 10.0))
      end
      @go2.setup
      expect(@go2).to have_received(:save_go2_settings).with(hash_including(mapdb_fwi_trinket: 'bracelet', delay: 10))
    end

    it 'limits DR presentation to its five supported settings without discarding GS data' do
      @scope.const_get(:XMLData).game = 'DR'
      @settings[:mapdb_fwi_trinket] = 'retained'
      allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
        expect(options[:fields].map { |field| field[:key] }).to contain_exactly(:echo_input, :hide_room_desc, :hide_room_titles, :delay, :typeahead)
        expect(options[:values][:mapdb_fwi_trinket]).to eq('retained')
        nil
      end
      @go2.setup
    end

    it 'uses the submitted FWI off value rather than the previously saved trinket' do
      user_vars = Struct.new(:mapdb_car_to_sos, :mapdb_car_from_sos, :mapdb_use_old_portals, :mapdb_use_urchins,
                             :mapdb_use_portmasters, :mapdb_use_day_pass, :day_pass_sack, :mapdb_ice_mode, :mapdb_use_portals,
                             :mapdb_buy_day_pass, :mapdb_fwi_trinket, :rogue_password).new
      user_vars.mapdb_fwi_trinket = 'bracelet'
      @scope.const_set(:UserVars, user_vars)
      @scope.const_set(:CharSettings, {})
      allow(@go2).to receive(:save_go2_settings).and_call_original
      @go2.save_go2_settings(@go2::SETUP_DEFAULTS.merge(mapdb_fwi_trinket: 'off'))
      expect(user_vars.mapdb_fwi_trinket).to be_nil
      @go2.save_go2_settings(@go2::SETUP_DEFAULTS.merge(mapdb_fwi_trinket: 'new bracelet'))
      expect(user_vars.mapdb_fwi_trinket).to eq('new bracelet')
    end

    it 'browser saves go2 travel preferences', browser: true do
      browser_host(:fixture_owner) { @go2.setup }
      expect(@go2).to have_received(:save_go2_settings).with(hash_including(mapdb_fwi_trinket: 'bracelet', delay: 10))
    end
  end
end
