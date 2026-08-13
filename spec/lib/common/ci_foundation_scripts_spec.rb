# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'spec_helper'

RSpec.describe 'CI foundation guard scripts' do
  let(:root) { Dir.mktmpdir('lich-ci-foundation') }

  after { FileUtils.remove_entry(root) }

  it 'rejects a shim namespace reference outside the shim directory' do
    FileUtils.mkdir_p(File.join(root, 'lib'))
    File.write(File.join(root, 'lib', 'violation.rb'), 'Lich::Common::ScriptScope' + '::Gtk')
    _output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_shim_namespace.rb'), root)
    expect(status).not_to be_success
  end

  it 'scans the Ruby entrypoint' do
    File.write(File.join(root, 'lich.rbw'), 'Lich::Common::ScriptScope' + '::Gtk')

    _output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_shim_namespace.rb'), root)

    expect(status).not_to be_success
  end

  it 'scans similarly-prefixed paths outside the shim directory' do
    FileUtils.mkdir_p(File.join(root, 'lib', 'common', 'script_scope'))
    File.write(File.join(root, 'lib', 'common', 'script_scope', 'gtk_extra.rb'), 'ScriptScope' + '::Gtk')

    _output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_shim_namespace.rb'), root)

    expect(status).not_to be_success
  end

  it 'rejects bare Gtk in the ScriptScope lexical namespace' do
    FileUtils.mkdir_p(File.join(root, 'lib'))
    source = ["module Lich", "  module Common", "    module ScriptScope", "      G" + "tk", "    end", "  end", "end"].join("\n")
    File.write(File.join(root, 'lib', 'collision.rb'), source)
    _output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_shim_namespace.rb'), root)
    expect(status).not_to be_success
  end

  it 'ignores shim names that appear only in strings and comments' do
    FileUtils.mkdir_p(File.join(root, 'lib'))
    source = ["# Lich::Common::ScriptScope::Gtk", "'module Lich module Common module ScriptScope Gtk'"].join("\n")
    File.write(File.join(root, 'lib', 'allowed.rb'), source)

    _output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_shim_namespace.rb'), root)

    expect(status).to be_success
  end

  it 'rejects non-ASCII Ruby source' do
    FileUtils.mkdir_p(File.join(root, 'lib'))
    File.binwrite(File.join(root, 'lib', 'violation.rb'), "# " + [0xC3, 0xA9].pack('C*') + "\n")
    _output, status = Open3.capture2e(RbConfig.ruby, '-S', 'rubocop', '--only', 'Custom/AsciiOnlySource', File.join(root, 'lib', 'violation.rb'))
    expect(status).not_to be_success
  end

  it 'expands the security manifest into twenty neutral pending check runs' do
    output, status = Open3.capture2e(RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/security_check_runs.rb'),
                                     File.join(LIB_DIR, '..', '.github/ci/security-test-manifest.json'))
    expect(status).to be_success
    payloads = JSON.parse(output)
    expect(payloads).to have_attributes(length: 20)
    expect(payloads.map { |payload| payload['name'] }.uniq.length).to eq(20)
    expect(payloads.map { |payload| payload['conclusion'] }.uniq).to eq(['neutral'])
  end

  it 'validates the complete security manifest and its leakage method' do
    manifest = File.join(LIB_DIR, '..', '.github/ci/security-test-manifest.json')
    _output, status = Open3.capture2e(
      RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_security_manifest.rb'), manifest
    )
    expect(status).to be_success
  end

  it 'rejects an incomplete leakage canary method' do
    manifest = JSON.parse(File.read(File.join(LIB_DIR, '..', '.github/ci/security-test-manifest.json')))
    leakage = manifest.fetch('tests').find { |entry| entry.fetch('id') == 'sec-bulk-leakage' }
    leakage.fetch('method').fetch('sinks').delete('error output')
    invalid_manifest = File.join(root, 'security-test-manifest.json')
    File.write(invalid_manifest, JSON.generate(manifest))

    _output, status = Open3.capture2e(
      RbConfig.ruby, File.join(LIB_DIR, '..', 'script/ci/check_security_manifest.rb'), invalid_manifest
    )

    expect(status).not_to be_success
  end

  it 'rejects implemented entries without an actual result' do
    require File.join(LIB_DIR, '..', 'script/ci/security_check_runs')
    entry = { 'id' => 'one', 'check_name' => 'one', 'state' => 'implemented' }
    expect { SecurityCheckRuns.build([entry]) }.to raise_error(KeyError)
  end

  it 'uses actual implemented results' do
    require File.join(LIB_DIR, '..', 'script/ci/security_check_runs')
    entry = { 'id' => 'one', 'check_name' => 'one', 'state' => 'implemented' }
    expect(SecurityCheckRuns.build([entry], results: { 'one' => 'failure' }).map { |item| item['conclusion'] }.uniq).to eq(['failure'])
    expect(SecurityCheckRuns.build([entry], results: { 'one' => 'success' }).map { |item| item['conclusion'] }.uniq).to eq(['success'])
  end

  it 'rejects unknown security states and neutral implemented results' do
    require File.join(LIB_DIR, '..', 'script/ci/security_check_runs')
    unknown = { 'id' => 'one', 'check_name' => 'one', 'state' => 'unknown' }
    implemented = { 'id' => 'one', 'check_name' => 'one', 'state' => 'implemented' }

    expect { SecurityCheckRuns.build([unknown], results: { 'one' => 'success' }) }.to raise_error(ArgumentError, /invalid state/)
    expect { SecurityCheckRuns.build([implemented], results: { 'one' => 'neutral' }) }.to raise_error(ArgumentError, /invalid implemented conclusion/)
    expect { SecurityCheckRuns.build([implemented], results: { 'one' => 'skipped' }) }.to raise_error(ArgumentError, /invalid implemented conclusion/)
  end

  it 'accepts readiness, writes distinct artifacts, and terminates a long-running fixture' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
    fixture = File.join(root, 'ready.rb')
    File.write(fixture, "warn 'startup output'\nLichCiStartupProbe.report!\nsleep 30\n")
    result = StartupLoadCheck.run_mode('fixture', [], fixture, File.join(LIB_DIR, '..'), 1, root)
    expect(result['verdict']).to eq('pass')
    expect(result['reached_startup']).to be(true)
    expect(result['loaded_features']).not_to be_empty
    expect(File.read(result['log_path'])).to include('startup output')
    expect(result['log_path']).to end_with('fixture.log')
    expect(result['result_path']).to end_with('fixture.result.json')
    expect(JSON.parse(File.read(result['loaded_features_path']))).to eq(result['loaded_features'])
    expect(JSON.parse(File.read(result['result_path']))['verdict']).to eq('pass')
  end

  it 'times out a startup that never reports readiness' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
    fixture = File.join(root, 'timeout.rb')
    File.write(fixture, "sleep 30\n")

    result = StartupLoadCheck.run_mode('timeout', [], fixture, File.join(LIB_DIR, '..'), 0.05, root)

    expect(result).to include('verdict' => 'fail', 'reached_startup' => false, 'failure_reason' => 'startup readiness timeout')
    expect(File).to exist(result['log_path'])
    expect(File).to exist(result['result_path'])
  end

  it 'aggregates exactly the four supported modes and writes a summary artifact' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
    fixture = File.join(root, 'all_modes.rb')
    artifact_dir = File.join(root, 'artifacts')
    File.write(fixture, "warn ARGV.join(' ')\nLichCiStartupProbe.report!\n")

    results, returned_artifact_dir = StartupLoadCheck.run(
      entrypoint: fixture, root: File.join(LIB_DIR, '..'), timeout: 1, artifact_dir: artifact_dir, install_fixtures: false
    )

    expect(returned_artifact_dir).to eq(artifact_dir)
    expect(results.map { |result| result['mode'] }).to eq(StartupLoadCheck::MODES.keys)
    expect(results.map { |result| result['argv'] }).to eq(StartupLoadCheck::MODES.values)
    expect(results.map { |result| result['verdict'] }.uniq).to eq(['pass'])
    expect(JSON.parse(File.read(File.join(artifact_dir, 'summary.json'))).fetch('results').length).to eq(4)
    results.each do |result|
      expect(File).to exist(result['log_path'])
      expect(File).to exist(result['loaded_features_path'])
      expect(File).to exist(result['result_path'])
    end
  end

  %w[exit_zero exit_nonzero malformed duplicate empty invalid_event invalid_features].each do |kind|
    it "rejects #{kind} startup protocol output" do
      require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
      fixture = File.join(root, "#{kind}.rb")
      body = case kind
             when 'exit_zero' then 'exit 0'
             when 'exit_nonzero' then 'exit 1'
             when 'malformed' then 'IO.for_fd(Integer(ENV.fetch("LICH_CI_STARTUP_FD")), "w").puts("no")'
             when 'duplicate' then 'w=IO.for_fd(Integer(ENV.fetch("LICH_CI_STARTUP_FD")), "w"); 2.times { w.puts(%q({"event":"startup_complete","loaded_features":["x"]})) }'
             when 'empty' then 'IO.for_fd(Integer(ENV.fetch("LICH_CI_STARTUP_FD")), "w").puts(%q({"event":"startup_complete","loaded_features":[]}))'
             when 'invalid_event' then 'IO.for_fd(Integer(ENV.fetch("LICH_CI_STARTUP_FD")), "w").puts(%q({"event":"other","loaded_features":["x"]}))'
             else 'IO.for_fd(Integer(ENV.fetch("LICH_CI_STARTUP_FD")), "w").puts(%q({"event":"startup_complete","loaded_features":[1]}))'
             end
      File.write(fixture, body)
      result = StartupLoadCheck.run_mode(kind, [], fixture, File.join(LIB_DIR, '..'), 1, root)
      expect(result['verdict']).to eq('fail')
      expect(result['reached_startup']).to be(false)
    end
  end

  ['LoadError: cannot load such file -- gtk3', 'NameError: uninitialized constant Gtk'].each_with_index do |message, index|
    it "rejects GTK-family startup error #{index + 1} even after valid readiness" do
      require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
      fixture = File.join(root, "gtk_error_#{index}.rb")
      File.write(fixture, "warn #{message.inspect}\nLichCiStartupProbe.report!\nsleep 30\n")

      result = StartupLoadCheck.run_mode("gtk-error-#{index}", [], fixture, File.join(LIB_DIR, '..'), 1, root)

      expect(result).to include(
        'verdict'         => 'fail',
        'reached_startup' => true,
        'failure_reason'  => 'GTK-family LoadError or NameError observed'
      )
    end
  end

  it 'does not confuse an unrelated load error with a GTK-family failure' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_load_check')
    fixture = File.join(root, 'other_load_error.rb')
    File.write(fixture, "warn 'LoadError: optional-other-gem'\nLichCiStartupProbe.report!\nsleep 30\n")

    result = StartupLoadCheck.run_mode('other-load-error', [], fixture, File.join(LIB_DIR, '..'), 1, root)

    expect(result['verdict']).to eq('pass')
  end

  it 'installs deterministic saved-login and GUI fixtures in the preloaded helper' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_probe')
    common = Module.new
    authentication = Module.new
    cli = Module.new { define_singleton_method(:execute) { :original } }
    authentication.const_set(:CLI, cli)
    common.const_set(:Authentication, authentication)
    stub_const('Lich::Common', common)
    allow(LichCiStartupProbe).to receive(:launch_data).and_return(['fixture-launch-data'])

    cli_trace = double('CLI trace', path: '/common/authentication/cli.rb', self: cli)
    LichCiStartupProbe.install_cli_fixture(cli_trace)

    gui_trace = double('GUI trace', path: '/common/gui_login.rb', self: common)
    LichCiStartupProbe.install_gui_fixture(gui_trace)
    gui_host = Object.new.extend(common)

    expect(cli.execute('CiFixture')).to eq(['fixture-launch-data'])
    expect(gui_host.gui_login).to eq(['fixture-launch-data'])
  end

  it 'rewrites direct mode to the local fixture server and emits complete launch data' do
    require File.join(LIB_DIR, '..', 'script/ci/startup_probe')
    local_address = double('local address', ip_port: 42_424)
    game_server = double('game server', local_address: local_address)
    LichCiStartupProbe.instance_variable_set(:@game_server, game_server)
    original_argv = ARGV.dup
    ARGV.replace(['--pipe', '--no-gui', '-g', 'localhost:1'])

    LichCiStartupProbe.rewrite_direct_target!
    launch_data = LichCiStartupProbe.launch_data

    expect(ARGV).to include('127.0.0.1:42424')
    expect(launch_data).to include('GAMEHOST=127.0.0.1', 'GAMEPORT=42424', 'KEY=CI-STARTUP-PROBE')
    expect(launch_data.grep(/CUSTOMLAUNCH=/).first).to include('startup_fixture_client.rb', '%port%')
  ensure
    ARGV.replace(original_argv) if original_argv
  end

  it 'wires the real CI commands, artifacts, and pull-request head SHA' do
    workflow = File.read(File.join(LIB_DIR, '..', '.github/workflows/ci-foundation.yaml'))

    expect(workflow).to include('gtk: [without-gtk3, with-gtk3]')
    gtk_prerequisites = workflow.index('- name: Install GTK build prerequisites')
    first_ruby_setup = workflow.index('- uses: ruby/setup-ruby@')
    expect(gtk_prerequisites).to be < first_ruby_setup
    expect(workflow).to include("if: matrix.gtk == 'with-gtk3'")
    expect(workflow).to include('libgirepository1.0-dev')
    expect(workflow).to include('libgtk-3-dev')
    expect(workflow.scan('ruby/setup-ruby@0dafeac902942906541bc140009cdbf32665b601').length).to eq(3)
    expect(workflow.scan('bundler-cache: true').length).to eq(2)
    expect(workflow).to include('echo "ruby_path=$ruby_path"')
    expect(workflow.scan('abort unless RUBY_VERSION == ARGV.fetch(0)').length).to eq(3)
    expect(workflow).not_to match(/rbenv|RBENV_VERSION/)
    expect(workflow).to include('run: bundle exec rspec')
    expect(workflow).to include('run: ruby script/ci/check_shim_namespace.rb')
    expect(workflow).to include('run: bundle exec rubocop --only Custom/AsciiOnlySource')
    expect(workflow).to include('run: ruby script/ci/startup_load_check.rb')
    expect(workflow).to include('LICH_CI_ARTIFACT_DIR: ${{ runner.temp }}/gtk-free-startup-loads')
    expect(workflow).to include("const headSha = context.eventName === 'pull_request'")
    expect(workflow).to include('context.payload.pull_request.head.sha')
    expect(workflow).to include('head_sha: headSha')
    expect(workflow).not_to include('head_sha: context.sha')
    expect(workflow).to include('checks: write')
    expect(workflow).to include('await github.rest.checks.create')
    expect(workflow).to include('conclusion: payload.conclusion')
  end
end
