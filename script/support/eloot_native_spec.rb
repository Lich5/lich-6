# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'

RSpec.describe 'native Eloot setup' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/eloot.lic'))
    definitions = @source[/module ELoot # UI Setup\n.*?(?=module ELoot # Profile loading)/m]
    expect(definitions).not_to include('Gtk::'), 'native Eloot setup is missing'
    @scope = Module.new
    @scope.module_eval(definitions, 'eloot.lic')
    @eloot = @scope::ELoot
    @store = { vendor_extension: 'retain', gem_horde_inv: [{ 'name' => 'ruby', 'count' => 3 }],
               loot_types: ['custom'], use_incremental_tipping: true, use_standard_tipping: false }
    @saves, @tips = [], []
    allow(@eloot).to receive(:save_profile) { @saves << Marshal.load(Marshal.dump(@store)) }
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
    @setup = @eloot::Setup.new(@store, owner: :eloot_fixture, availability: { loot_phase: false }, lockers: ['Town'],
      spell_exists: proc { |number| [101, 401].include?(number) }, tipper: proc { |number, base, maximum, alpha| @tips << [number, base, maximum, alpha]; base + number })
  end

  after do
    @setup&.form&.close
    @host&.stop
  end

  def fire(label, values = {})
    @setup.form.show unless @setup.form.page
    render = @setup.form.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == label }
    expect(button).not_to be_nil
    submission = render.tree.each.to_h { |node| [node.cid, values.fetch(node.props[:key], node.props.key?(:value) ? node.props[:value] : node.props[:checked])] }
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  it 'normalizes arrays and exclusive modes without losing custom loot types or runtime inventory' do
    @setup.form.show
    fire('Save & Close', 'loot_types:gem' => true, 'loot_exclude' => "urglaes\nblack ora\nurglaes", 'loot_phase' => true,
      'tip_mode' => 'standard', 'gem_list_mode' => 'only', 'gem_locker_mode' => 'che', 'gem_horde_che_rooms' => '1234',
      'sell_keep_scrolls' => "401v\n101\n401v")
    saved = @setup.form.wait
    expect(saved).to include(vendor_extension: 'retain', loot_types: ['custom', 'gem'], loot_exclude: ['black ora', 'urglaes'], loot_phase: false,
                             use_standard_tipping: true, use_incremental_tipping: false, gem_only_list: true, gem_everything_list: false,
                             gem_horde_locker: false, gem_horde_locker_che: true, sell_keep_scrolls: ['101', '401v'])
    expect(saved[:gem_horde_inv]).to eq(@store[:gem_horde_inv])
    expect(@saves).to be_empty
    expect(@store).not_to have_key(:gem_only_list)
  end

  it 'previews tipping from submitted draft values without saving and cancels without changing the profile' do
    original = Marshal.load(Marshal.dump(@store))
    fire('Preview incremental tips', 'base_tip' => 350, 'max_tip' => 3000, 'alpha_rate' => 3.5)
    expect(@tips).to include([5, 350, 3000, 3.5])
    expect(@saves).to be_empty
    fire('Cancel')
    expect(@setup.form.wait).to be_nil
    expect(@store).to eq(original)
  end

  it 'rejects an unknown scroll spell while retaining the editable draft' do
    fire('Save & Close', 'sell_keep_scrolls' => '9999')
    nodes = @setup.form.page.last_render.tree.each.to_a
    expect(nodes.find { |node| node.props[:key] == 'validation' }.props[:content]).to include('9999')
    expect(@host.registry.pages_for(:eloot_fixture)).not_to be_empty
    expect(nodes.find { |node| node.props[:key] == 'sell_keep_scrolls' }.props[:value]).to eq('9999')
    expect(@saves).to be_empty
  end

  it 'persists one accepted result on the script thread and restores memory if persistence fails' do
    accepted = @store.merge(loot_keep: ['ruby'])
    allow(@setup.form).to receive(:show).and_return(@setup.form)
    allow(@setup.form).to receive(:wait).and_return(accepted)
    @setup.start
    expect(@saves).to eq([accepted])
    original = @store.dup
    allow(@setup.form).to receive(:wait).and_return(accepted.merge(loot_keep: ['diamond']))
    allow(@eloot).to receive(:save_profile).and_raise(IOError, 'fixture write failure')
    expect { @setup.start }.to raise_error(IOError)
    expect(@store).to eq(original)
  end

  it 'browser previews draft tips, edits a list and saves across tabs', browser: true do
    @setup.form.show
    @host.start
    puts "ELOOT_BROWSER_URL=#{@host.launch_url(page: @setup.form.page)}"
    $stdout.flush
    waiter = Thread.new { @setup.form.wait }
    expect(waiter.join(180)).to equal(waiter)
    expect(waiter.value).to include(base_tip: 350, loot_keep: ['ruby'], use_incremental_tipping: true)
    expect(@tips).to include([5, 350, 2000, 2.5])
  ensure
    waiter&.kill if waiter&.alive?
  end
end
