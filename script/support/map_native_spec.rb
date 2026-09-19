# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'
require 'tmpdir'
require 'base64'
require 'json'
require 'uri'
require 'monitor'

RSpec.describe 'native map' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/map.lic'))
    definitions = @source[/  class NativeMap\n.*?(?=  # Native map entrypoint)/m]
    expect(definitions).not_to be_nil, 'native map controller is missing'
    @scope = Module.new
    @scope.const_set(:MapData, Class.new)
    @scope::MapData.const_set(:MAP_LINKS, [])
    @scope.module_eval(definitions, 'map.lic')
    @directory = Dir.mktmpdir('native-map')
    # A valid 1x1 fixture image; dimensions in this test are overridden to make
    # deterministic room regions visible without creating a game asset.
    png = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1sAAAAASUVORK5CYII=')
    File.binwrite(File.join(@directory, 'fixture.png'), png)
    allow(Lich::WebUI::ImageSize).to receive(:read).and_return([240, 160])
    room_type = Struct.new(:id, :image, :image_coords, :tags, :location)
    @first = room_type.new(1, 'fixture.png', [10, 10, 40, 40], ['bank'], 'Town')
    @second = room_type.new(2, 'fixture.png', [60, 60, 90, 90], ['shop'], 'Town')
    @rooms = double('map rooms', list: [@first, @second], current: @first)
    allow(@rooms).to receive(:[]) { |id| [@first, @second].find { |room| room.id.to_s == id.to_s } }
    @settings = {}
    allow(@settings).to receive(:save)
    @travel = []
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
    @map = @scope::NativeMap.new(owner: :map_fixture, map_dir: @directory, rooms: @rooms, settings: @settings,
                                 notes_path: File.join(@directory, 'notes.json'), travel: proc { |id| @travel << id })
    @map.show
  end

  after do
    @map&.close
    @host&.stop
    FileUtils.remove_entry(@directory) if @directory
  end

  def fire(label, values = {})
    render = @map.page.last_render
    button = render.tree.each.find { |node| node.props[:label] == label && node.type == :button }
    expect(button).not_to be_nil
    submission = render.tree.each.to_h { |node| [node.cid, values.fetch(node.props[:key], node.props[:value] || node.props[:checked])] }
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  it 'uses a served native image, navigates exact room coordinates and keeps modified clicks non-travelling' do
    expect(@source.gsub(/=begin.*?=end/m, '')).not_to match(/Gtk::|Gtk\.queue|GdkPixbuf::|Cairo::/)
    composite = @map.page.last_render.tree.each.find { |node| node.type == :composite }
    expect(composite.props[:layers].first[:src]).to start_with('/files/')
    expect(@travel).to be_empty
    @map.click(x: 70, y: 70, button: 'primary', modifiers: ['shift'])
    expect(@travel).to be_empty
    @map.click(x: 70, y: 70, button: 'primary', modifiers: [])
    expect(@travel).to eq([2])
  end

  it 'keeps Find temporary, saves explicit map settings and merges notes without losing other rooms' do
    fire('Find room', 'find-room' => '2')
    expect(@settings).not_to have_received(:save)
    fire('Apply settings', 'scale' => 1.5, 'follow' => false)
    expect(@settings).to include('global_scale' => 1.0, 'follow_mode' => false, 'map_scale' => { 'fixture.png' => 1.5 })
    File.write(File.join(@directory, 'notes.json'), JSON.generate('other' => 'preserved'))
    fire('Save note', 'note-2' => 'Fixture note')
    expect(JSON.parse(File.read(File.join(@directory, 'notes.json')))).to eq('other' => 'preserved', '2' => 'Fixture note')
  end

  it 'retains the current and found markers when many notes exceed the display bound' do
    extra = (3..300).map { |id| @first.class.new(id, 'fixture.png', [1, 1, 4, 4], [], 'Town') }
    @map.instance_variable_set(:@by_map, { 'fixture.png' => extra + [@first, @second] })
    @map.instance_variable_set(:@notes, extra.to_h { |room| [room.id.to_s, 'note'] })
    fire('Find room', 'find-room' => '2')
    nodes = @map.page.last_render.tree.each.to_a
    surface = nodes.find { |node| node.type == :composite }
    expect(surface.props[:layers].size).to be <= 512
    expect(surface.props[:layers].filter_map { |layer| layer[:key] }).to include('current', 'find')
    expect(nodes.find { |node| node.props[:key] == 'following' }.props[:content]).to include('paused')
  end

  it 'refuses a cross-room two-click correction and discards a half-finished correction on close' do
    fire('Apply settings', 'fix-mode' => true)
    @map.click(x: 5, y: 6, button: 'primary', modifiers: %w[ctrl shift])
    allow(@rooms).to receive(:current).and_return(@second)
    @map.click(x: 20, y: 25, button: 'primary', modifiers: %w[ctrl shift])
    expect(@first.image_coords).to eq([10, 10, 40, 40])
    expect(@second.image_coords).to eq([60, 60, 90, 90])
    @map.close
    expect(@host.registry.pages_for(:map_fixture)).to be_empty
  end

  it 'makes marker choices beyond the select bound reachable through explicit filtering' do
    tags = (1..600).map { |n| "tag-#{n.to_s.rjust(3, '0')}" }
    @map.instance_variable_set(:@tag_choices, tags)
    Lich::WebUI.refresh(@map.page)
    fire('Filter marker choices', 'marker-filter' => 'tag-600')
    nodes = @map.page.last_render.tree.each.to_a
    select = nodes.find { |node| node.props[:label] == 'Tag markers' }
    expect(select.props[:options].map { |option| option[:value] }).to include('tag-600')
    expect(select.props[:options].size).to be <= 512
  end

  it 'browser finds a room, saves its note, scales the map and closes', browser: true do
    @host.start
    puts "MAP_BROWSER_URL=#{@host.launch_url(page: @map.page)}"
    $stdout.flush
    waiter = Thread.new { @map.wait }
    expect(waiter.join(180)).to equal(waiter)
    expect(JSON.parse(File.read(File.join(@directory, 'notes.json')))['2']).to eq('Fixture note')
    expect(@settings['map_scale']['fixture.png']).to eq(1.5)
  ensure
    waiter&.kill if waiter&.alive?
  end
end
