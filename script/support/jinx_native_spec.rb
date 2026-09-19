# frozen_string_literal: true

# Loads the production native controller and logger. Repository and installation
# effects are fixtures; no manifest fetch, download or live script is performed.
require_relative '../../spec/spec_helper'
require 'webui'
require 'cgi'
require 'digest/sha1'
require 'timeout'

RSpec.describe 'Jinx native package browser' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    @source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/jinx.lic'))
    stub_const('Lich::Common::Jinx', Module.new)
    logger = @source[/module ::Lich\n  module Common\n    module Jinx\n      module Log\n.*?(?=\nmodule ::Lich)/m]
    Object.class_eval(logger, 'jinx.lic')
    definitions = @source.split("# GUI MODULE\n# ===========================", 2).last.split("\nif defined?(Lich::Util)", 2).first
    Object.class_eval(definitions, 'jinx.lic')
    @repo = double('repository catalog')
    @cli = double('Jinx commands')
    @folders = double('Jinx directories', script_dir: '/fixture/scripts', data_dir: '/fixture/data')
    @rows = [{ name: :fixture, url: 'https://fixture.invalid' }]
    allow(@repo).to receive(:to_a).and_return(@rows)
    allow(@repo).to receive(:manifest) do |repo|
      repo.merge(available: [{ file: 'alpha.lic', type: 'script', last_commit: 1 },
                             { file: 'map.dat', type: 'data', last_commit: 2 }])
    end
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with('/fixture/scripts/alpha.lic').and_return(false)
    allow(File).to receive(:exist?).with('/fixture/data/map.dat').and_return(false)
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
    @browser = Lich::Common::Jinx::GUI::Browser.new(owner: :jinx_fixture, catalog: @repo, actions: @cli, directories: @folders)
    @browser.show(load: false)
    @browser.refresh_data
  end

  after do
    @browser&.close
    @host&.stop
  end

  def fire(label, values = {})
    render = @browser.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == label }
    expect(button).not_to be_nil, "missing #{label}"
    submission = render.tree.each.to_h { |node| [node.cid, values.fetch(node.props[:key], node.props[:value] || node.props[:checked])] }
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  def select(kind, key)
    render = @browser.page.last_render
    table = render.tree.each.find { |node| node.props[:key] == "#{kind}-table" }
    render.bindings.fetch([table.cid, :selection_change]).call(Struct.new(:payload).new({ rows: [key] }))
  end

  def finish_work
    expect(@browser.worker.join(5)).to equal(@browser.worker)
    @browser.worker.value
  end

  it 'renders cached rows without fetching again, GTK, or a global logger swap' do
    expect(@source).not_to match(/Gtk::|Gtk\.queue|require ['"]gtk3|remove_const, :Log/)
    expect(@repo).not_to receive(:manifest)
    Lich::WebUI.refresh(@browser.page)
    tables = @browser.page.last_render.tree.each.select { |node| node.type == :table }
    expect(tables.map { |table| table.props[:rows].size }).to eq([1, 1, 1])
  end

  it 'submits force only with the exact selected asset and keeps information capture thread-local' do
    original = Lich::Common::Jinx::Log
    select('script', 'script-0')
    expect(@cli).to receive(:script_info).with('alpha.lic', 'fixture') do
      original.mono('<b>Alpha documentation</b>')
      expect(Thread.new { Thread.current[:jinx_native_log] }.value).to be_nil
    end
    fire('Info alpha.lic')
    finish_work
    expect(Lich::Common::Jinx::Log).to equal(original)
    expect(@browser.page.last_render.tree.each.any? { |node| node.props[:content] == 'Alpha documentation' }).to be(true)
    expect(@cli).to receive(:script_update).with('alpha.lic', 'fixture', force: true)
    fire('Update alpha.lic', 'script-force' => true)
    finish_work
  end

  it 'rejects an invalid repository URL before calling the command and preserves cancellation' do
    expect(@cli).not_to receive(:repo_add)
    fire('Add repository', 'repo-name' => 'bad', 'repo-url' => 'file:///etc/passwd')
    finish_work
    expect(@browser.page.last_render.tree.each.any? { |node| node.props[:content].to_s.include?('HTTPS') }).to be(true)
    fire('Close')
    expect(@host.registry.pages_for(:jinx_fixture)).to eq([])
  end

  it 'refuses a second operation while busy and releases the worker on close' do
    entered = Queue.new
    blocked = Queue.new
    allow(@cli).to receive(:repo_add) { entered << true; blocked.pop }
    fire('Add repository', 'repo-name' => 'added', 'repo-url' => 'https://fixture.invalid/new')
    Timeout.timeout(2) { entered.pop }
    expect(@browser.perform('second') { raise 'must not run' }).to be(false)
    @browser.close
    expect(@browser.worker.alive?).to be(false)
  ensure
    blocked&.push(true)
  end

  it 'cleans up the gated worker when owner thread adoption fails' do
    group = double('closed thread group')
    allow(group).to receive(:add).and_raise(ThreadError, 'group is closed')
    owner = Struct.new(:thread_group).new(group)
    browser = Lich::Common::Jinx::GUI::Browser.new(owner: owner, catalog: @repo, actions: @cli, directories: @folders)
    expect { browser.perform('cannot adopt') { raise 'must not run' } }.to raise_error(ThreadError)
    expect(browser.worker.alive?).to be(false)
  ensure
    browser&.close
  end

  it 'releases its page when initial browser opening fails' do
    owner = :failed_open
    browser = Lich::Common::Jinx::GUI::Browser.new(owner: owner, catalog: @repo, actions: @cli, directories: @folders)
    allow(Lich::WebUI).to receive(:open).and_raise(IOError, 'fixture open failed')
    expect { browser.show(load: false) }.to raise_error(IOError)
    expect(@host.registry.pages_for(owner)).to be_empty
  ensure
    browser&.close
  end

  it 'browser searches, reads information and updates only the fixture asset', browser: true do
    allow(@cli).to receive(:script_info) { Lich::Common::Jinx::Log.mono('<b>Alpha documentation</b>') }
    allow(@cli).to receive(:script_update)
    @host.start
    puts "JINX_BROWSER_URL=#{@host.launch_url(page: @browser.page)}"
    $stdout.flush
    waiter = Thread.new { @browser.wait }
    expect(waiter.join(180)).to equal(waiter)
    expect(@cli).to have_received(:script_info).with('alpha.lic', 'fixture')
    expect(@cli).to have_received(:script_update).with('alpha.lic', 'fixture', force: true)
  ensure
    waiter&.kill if waiter&.alive?
  end
end
