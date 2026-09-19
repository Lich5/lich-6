# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'

RSpec.describe 'native BlackArts setup' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/BlackArts.lic'))
    definitions = @source.split("# Setup\n", 2).last.split("# Main\n", 2).first
    expect(definitions).not_to include('Gtk::'), 'native BlackArts setup is missing'
    @scope = Module.new
    @scope.module_eval(definitions, 'BlackArts.lic')
    @arts = @scope::BlackArts
    @store = { vendor_extension: 'keep', item_include: ['custom reagent'], consignment_include: [],
               forage_options: ['custom'], names_a: 'rat', profile_a: 'warrior', no_magic: ['room'] }
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
    @setup = @arts::Setup.new(@store, owner: :blackarts_fixture, profiles: %w[warrior ranger], guilds: ['Landing'],
      availability: { use_wracking: false, 'skill_types:illusions' => false, 'forage_options:use_506' => false })
  end

  after { @setup&.form&.close; @host&.stop }

  def fire(label, values = {})
    @setup.form.show unless @setup.form.page
    render = @setup.form.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == label }
    submission = render.tree.each.to_h do |node|
      key = node.props[:key].to_s.sub(/--revision-\d+\z/, '')
      [node.cid, values.fetch(key, node.props.key?(:value) ? node.props[:value] : node.props[:checked])]
    end
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  it 'saves all ten profile routes, normalized lists and ability gates while preserving extensions' do
    @setup.form.show
    fields = @setup.form.page.last_render.tree.each.to_a
    expect(fields.count { |node| node.type == :select && node.props[:key].match?(/\Aprofile_[a-j]\z/) }).to eq(10)
    fire('Save & Close', 'profile_a' => 'ranger', 'names_a' => 'troll, orc', 'kill_a' => true,
      'home_guild' => 'Landing', 'recipe_exclude' => "second\nfirst\nsecond", 'use_wracking' => true,
      'skill_types:illusions' => true, 'forage_options:use_506' => true, 'forage_options:run' => true)
    expect(@setup.form.wait).to include(profile_a: 'ranger', profile_name_a: 'ranger', names_a: 'troll, orc', kill_a: true,
                                        home_guild: 'Landing', home_guild_name: 'Landing', recipe_exclude: %w[first second],
                                        use_wracking: false, skill_types: [], forage_options: %w[custom run], vendor_extension: 'keep', no_magic: ['room'])
    expect(@store[:profile_a]).to eq('warrior')
  end

  it 'restores a default list in the draft without saving or losing another field, then cancels' do
    original = Marshal.load(Marshal.dump(@store))
    fire('Reset reagent buying', 'guild_pause' => '120')
    fire('Reset consignment selling')
    nodes = @setup.form.page.last_render.tree.each.to_a
    expect(nodes.find { |node| node.props[:key].to_s.start_with?('item_include') }.props[:value]).to include('essence of air')
    expect(nodes.find { |node| node.props[:key].to_s.start_with?('guild_pause') }.props[:value]).to eq('120')
    fire('Cancel')
    expect(@setup.form.wait).to be_nil
    expect(@store).to eq(original)
  end

  it 'browser resets one list, selects a profile and saves', browser: true do
    @setup.form.show
    @host.start
    puts "BLACKARTS_BROWSER_URL=#{@host.launch_url(page: @setup.form.page)}"
    $stdout.flush
    waiter = Thread.new { @setup.form.wait }
    expect(waiter.join(180)).to equal(waiter)
    expect(waiter.value).to include(profile_a: 'ranger', names_a: 'troll')
    expect(waiter.value[:item_include]).to include('essence of air')
  ensure
    waiter&.kill if waiter&.alive?
  end
end
