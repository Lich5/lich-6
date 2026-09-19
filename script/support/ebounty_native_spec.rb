# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'
require 'yaml'
require 'timeout'

RSpec.describe 'EBounty native setup' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/ebounty.lic'))
    @scope = Module.new
    @scope.const_set(:XMLData, Struct.new(:game).new('GSF'))
    @scope.const_set(:Stats, Struct.new(:prof).new('Wizard'))
    @scope.const_set(:Skills, Struct.new(:slblessings).new(0))
    @scope.const_set(:Spell, Hash.new(Struct.new(:known?).new(false)))
    @scope.const_set(:Script, Struct.new(:current).new(:ebounty_fixture))
    @scope.const_set(:DATA_DIR, '/fixture')
    @scope.const_set(:Char, Struct.new(:name).new('Fixture'))
    definitions = @source.split('  class Setup', 2).last.split('  module Hunting', 2).first
    @scope.module_eval("module EBounty\n  class Setup#{definitions}\nend", 'ebounty.lic')
    @bounty = @scope::EBounty
    allow(@bounty).to receive(:get_script_version).and_return('fixture')
    allow(@bounty).to receive(:save_profile)
    allow(Dir).to receive(:exist?).with('/fixture/GSF/Fixture/bigshot_profiles').and_return(true)
    allow(Dir).to receive(:children).with('/fixture/GSF/Fixture/bigshot_profiles').and_return(%w[warrior.yaml ranger.yaml ignored.txt])
  end

  it 'cancels without changing the input or writing settings, including nil defaults' do
    expect(@source).not_to match(/Gtk::|Gtk\.queue|<interface>/)
    settings = { selling_script: nil, creature_exclude: ['troll'] }
    allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
      expect(options[:values][:selling_script]).to eq('eloot')
      nil
    end
    @bounty::Setup.new(settings).start
    expect(settings).to eq(selling_script: nil, creature_exclude: ['troll'])
    expect(@bounty).not_to have_received(:save_profile)
  end

  it 'normalizes exclusive choices, exclusions, all escort routes, profiles and ability gates on Save' do
    allow(Lich::WebUI::SettingsForm).to receive(:edit) do |**options|
      fields = options[:fields]
      expect(fields.count { |f| f[:key].to_s.start_with?('escort_types:') }).to eq(30)
      expect(fields.find { |f| f[:key] == :default_profile }[:options].map { |o| o[:value] }).to eq(['', 'ranger', 'warrior'])
      expect(fields.find { |f| f[:key] == :'forage_options:use_650' }[:disabled]).to be(true)
      expect(fields.find { |f| f[:key] == :wander_wait }).to include(min: 0.0, max: 100.0)
      result = options[:normalize].call(options[:values].merge(rest_mode: 'table_rest', hunting_mode: 'keep_hunting',
                                                               once_and_done: false, new_bounty_on_exit: true, ranger_track: true,
                                                               :'forage_options:use_650' => true, :'escort_types:landing_to_illy' => true,
                                                               creature_exclude: " troll\norc\ntroll \n", default_profile: 'warrior'))
      expect(result).to include(table_rest: true, bigshot_rest: false, keep_hunting: true, exp_pause: false, new_bounty_on_exit: false, ranger_track: false)
      expect(result[:creature_exclude]).to eq(%w[orc troll])
      expect(result[:forage_options]).to eq([])
      expect(result[:escort_types]).to eq(['landing_to_illy'])
      expect(result.keys.grep(/:/)).to eq([])
      result
    end
    @bounty::Setup.new({}).start
    expect(@bounty).to have_received(:save_profile).with(hash_including(default_profile: 'warrior'))
  end

  it 'browser selects a profile, rest mode and exclusions before Save', browser: true do
    host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(host)
    allow(Lich::WebUI).to receive(:registry).and_return(host.registry)
    allow(Lich::WebUI).to receive(:open)
    worker = Thread.new { @bounty::Setup.new({}).start }
    page = Timeout.timeout(5) do
      loop do
        current = host.registry.pages_for(:ebounty_fixture).first
        break current if current&.last_render
        worker.value unless worker.alive?
        sleep 0.01
      end
    end
    puts "EBOUNTY_BROWSER_URL=#{host.launch_url(page: page)}"
    $stdout.flush
    expect(worker.join(180)).to equal(worker)
    worker.value
    expect(@bounty).to have_received(:save_profile).with(hash_including(default_profile: 'warrior', table_rest: true, creature_exclude: %w[orc troll]))
  ensure
    worker&.kill if worker&.alive?
    host&.stop
  end
end
