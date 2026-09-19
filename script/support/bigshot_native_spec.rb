# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require 'tempfile'
require 'timeout'

RSpec.describe 'native Bigshot setup' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/bigshot.lic')).gsub("\r\n", "\n")
    definitions = @source.split("# Setup class for UI\n", 2).last.split("# Main\n", 2).first
    expect(definitions).not_to include('Gtk::'), 'native Bigshot setup is missing'
    @scope = Module.new
    @scope.module_eval(definitions, 'bigshot.lic')
    @directory = Dir.mktmpdir('bigshot-native')
    File.write(File.join(@directory, 'ranger.yaml'), { 'hunting_room_id' => '1234', 'vendor_extension' => 'profile', 'boons_flee' => ['blink'] }.to_yaml)
    @saved = []
    @setup = @scope::Bigshot::Setup.new({ 'hunting_room_id' => '100', 'vendor_extension' => 'current',
      'immunity' => ['future'], 'boons_ignore' => ['future_boon'], 'boon_flee_from' => false }, owner: :bigshot_fixture,
      directory: @directory, persist: proc { |settings| @saved << settings })
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
  end

  after do
    @setup&.form&.close
    @worker&.join(1)
    @worker&.kill if @worker&.alive?
    @host&.stop
    FileUtils.remove_entry(@directory) if @directory
  end

  def fire(label, values = {})
    @setup.form.show unless @setup.form.page
    render = @setup.form.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == label }
    expect(button).not_to be_nil
    submission = render.tree.each.to_h do |node|
      key = node.props[:key].to_s.sub(/--revision-\d+\z/, '')
      [node.cid, values.fetch(key, node.props.key?(:value) ? node.props[:value] : node.props[:checked])]
    end
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  it 'round-trips individual and group boon choices into the existing arrays without losing unknown extensions' do
    fire('Apply boon group', 'boon_group' => 'immunity', 'boon_mode' => 'flee', 'hunting_room_id' => '321')
    fire('Save & Close', 'boon:blink' => 'ignore', 'boon:stun_immune' => 'common')
    kind, saved = @setup.form.next_action
    expect(kind).to eq(:save)
    expect(saved).to include('hunting_room_id' => '321', 'vendor_extension' => 'current')
    expect(saved['boons_ignore']).to include('blink', 'future_boon')
    expect(saved['boons_flee']).to include('crit_death_immune')
    expect(saved['boons_flee']).not_to include('stun_immune')
    expect(saved['immunity']).to include('future', 'stun_immune_common')
    expect(saved.keys.grep(/\Aboon:/)).to be_empty
    expect(saved).not_to have_key('boon_flee_from')
  end

  it 'loads a profile into the draft and requires explicit overwrite for an existing profile' do
    @setup.form.show
    original = File.read(File.join(@directory, 'ranger.yaml'))
    fire('Load profile', 'profile_name' => 'ranger')
    @setup.process_action(*@setup.form.next_action)
    expect(@saved).to be_empty
    fire('Save named profile', 'save_profile_name' => 'ranger', 'hunting_room_id' => '777')
    @setup.process_action(*@setup.form.next_action)
    expect(File.read(File.join(@directory, 'ranger.yaml'))).to eq(original)
    expect(@setup.form.page.last_render.tree.each.any? { |node| node.props[:content].to_s.include?('overwrite') }).to be(true)
    fire('Save named profile', 'save_profile_name' => 'ranger', 'allow_overwrite' => true, 'hunting_room_id' => '777')
    @setup.process_action(*@setup.form.next_action)
    expect(YAML.safe_load_file(File.join(@directory, 'ranger.yaml'))).to include('hunting_room_id' => '777', 'vendor_extension' => 'profile')
    expect(@saved).to be_empty
    fire('Cancel')
    expect(@setup.form.next_action.first).to eq(:close)
  end

  it 'rejects traversal and symlink profiles and never writes outside the selected directory' do
    fire('Save named profile', 'save_profile_name' => '../outside')
    @setup.process_action(*@setup.form.next_action)
    expect(Dir.children(@directory)).to eq(['ranger.yaml'])
    File.symlink(File.join(@directory, 'ranger.yaml'), File.join(@directory, 'link.yaml'))
    expect { @setup.profile_store.load('link') }.to raise_error(ArgumentError, /symlink/)
    expect { @setup.profile_store.save('link', {}, overwrite: true) }.to raise_error(ArgumentError, /symlink/)
  end

  it 'shows repeated interaction alerts on one owned native page and closes it' do
    expect(@source).not_to match(/Gtk::|Gtk\.queue|GLib::/)
    alert = @scope::Bigshot::InteractionAlert.new(owner: :alert_fixture)
    alert.show('<literal interaction>')
    alert.show('second interaction')
    pages = @host.registry.pages_for(:alert_fixture)
    expect(pages.size).to eq(1)
    expect(pages.first.last_render.tree.each.any? { |node| node.props[:content] == 'second interaction' }).to be(true)
    alert.close
    expect(@host.registry.pages_for(:alert_fixture)).to be_empty
  end

  it 'browser loads a profile, changes boon handling and saves active settings', browser: true do
    @worker = Thread.new { @setup.start }
    page = Timeout.timeout(5) do
      loop do
        candidate = @host.registry.pages_for(:bigshot_fixture).first
        break candidate if candidate&.last_render
        @worker.value unless @worker.alive?
        sleep 0.01
      end
    end
    @host.start
    puts "BIGSHOT_BROWSER_URL=#{@host.launch_url(page: page)}"
    $stdout.flush
    expect(@worker.join(180)).to equal(@worker)
    @worker.value
    expect(@saved.one?).to be(true)
    expect(@saved.first).to include('hunting_room_id' => '5678', 'vendor_extension' => 'profile')
    expect(@saved.first['boons_ignore']).to include('blink')
  end
end
