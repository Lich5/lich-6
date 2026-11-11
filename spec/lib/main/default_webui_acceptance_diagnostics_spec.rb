# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../support/default_webui_acceptance_diagnostics'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'

RSpec.describe DefaultWebUIAcceptanceDiagnostics do
  it 'retains redirected startup logs and the last flushed stage after a real child is killed' do
    Dir.mktmpdir('lich acceptance diagnostics ') do |root|
      helper = File.expand_path('../../support/default_webui_acceptance_diagnostics.rb', __dir__)
      code = <<~RUBY
        root = ARGV.fetch(0)
        Dir.mkdir(File.join(root, 'temp'))
        $stderr = File.open(File.join(root, 'temp', 'debug-startup.log'), 'w')
        $stderr.sync = true
        warn 'startup blocked after dependency check'
        File.binwrite(File.join(root, 'temp', 'lich5-missing-gems.log'), "missing dependency\n" + [255].pack('C*'))
        DefaultWebUIAcceptanceDiagnostics.mark(root, 'probe_ready')
        DefaultWebUIAcceptanceDiagnostics.mark(root, 'gemcheck_entered')
        puts 'ready'
        $stdout.flush
        sleep 30
      RUBY
      Open3.popen3(RbConfig.ruby, '-r', helper, '-e', code, root) do |stdin, stdout, stderr, waiter|
        stdin.close
        expect(Timeout.timeout(5) { stdout.gets }).to eq("ready\n")
        Process.kill('KILL', waiter.pid)
        expect(waiter.join(5)).not_to be_nil
        expect(stderr.read).to eq('')

        # Capture preserves the redirected file's bytes, including Windows CRLF.
        startup_log = File.binread(File.join(root, 'temp', 'debug-startup.log')).force_encoding(Encoding::UTF_8)
        expect(startup_log).to match(/\Astartup blocked after dependency check\r?\n\z/)
        retained = described_class.capture(root)
        expect(retained).to include(
          'last_startup_stage' => 'gemcheck_entered',
          'startup_stages'     => ['probe_ready', 'gemcheck_entered'],
          'startup_logs'       => {
            'temp/debug-startup.log'      => startup_log,
            'temp/lich5-missing-gems.log' => "missing dependency\n" + [0xfffd].pack('U')
          }
        )
        FileUtils.remove_entry(File.join(root, 'temp'))
        expect(JSON.parse(JSON.generate(retained))).to eq(retained)
      ensure
        Process.kill('KILL', waiter.pid) if waiter&.alive?
        waiter&.join
      end
    end
  end

  it 'leaves the last stage unknown when startup produced no progress or logs' do
    Dir.mktmpdir('lich acceptance diagnostics ') do |root|
      expect(described_class.capture(root)).to eq(
        'last_startup_stage' => nil, 'startup_stages' => [], 'startup_logs' => {}
      )
    end
  end
end
