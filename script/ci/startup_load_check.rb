#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

module StartupLoadCheck
  MODES = { 'default' => [], 'saved-character-login' => ['--login', 'CiFixture', '--no-gui'],
            'headless-detachable-login' => ['--login', 'CiFixture', '--headless', 'auto'],
            'direct-pipe-launch' => ['--pipe', '--no-gui', '-g', 'localhost:1'] }.freeze
  ERROR_CLASS_PATTERN = /\b(?:LoadError|NameError)\b/
  GTK_FAMILY_PATTERN = /\b(?:gtk(?:2|3|4)?|gdk(?:2|3|4)?|gobject(?:-introspection)?|glib2?)\b/i

  def self.run(entrypoint: 'lich.rbw', root: Dir.pwd, timeout: 15, artifact_dir: nil, install_fixtures: true)
    artifact_dir ||= Dir.mktmpdir('lich-ci-loads')
    FileUtils.mkdir_p(artifact_dir)
    results = MODES.map do |mode, argv|
      run_mode(mode, argv, entrypoint, root, timeout, artifact_dir, install_fixtures: install_fixtures)
    end
    File.write(File.join(artifact_dir, 'summary.json'), JSON.pretty_generate('results' => results))
    [results, artifact_dir]
  end

  def self.run_mode(mode, argv, entrypoint, root, timeout, artifact_dir, install_fixtures: false)
    FileUtils.mkdir_p(artifact_dir)
    log_path = File.join(artifact_dir, "#{mode}.log")
    result_path = File.join(artifact_dir, "#{mode}.result.json")
    loaded_features_path = File.join(artifact_dir, "#{mode}.loaded-features.json")
    reader = writer = stdin = output = wait = drain = nil
    raw = ''
    log = +''
    timed_out = false
    protocol_error = nil

    begin
      reader, writer = IO.pipe
      env = { 'LICH_CI_STARTUP_FD' => writer.fileno.to_s, 'RUBYOPT' => "-r#{File.join(root, 'script/ci/startup_probe.rb')}" }
      env['LICH_CI_STARTUP_FIXTURES'] = '1' if install_fixtures
      stdin, output, wait = Open3.popen2e(
        env, RbConfig.ruby, entrypoint, *argv, chdir: root, pgroup: true, writer.fileno => writer
      )
      writer.close
      drain = Thread.new { log << output.read }
      ready = IO.select([reader], nil, nil, timeout)
      if ready
        raw = read_readiness(reader)
      else
        timed_out = true
      end
    rescue SystemCallError, IOError => e
      protocol_error = "startup protocol error: #{e.class}: #{e.message}"
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      stdin&.close unless stdin&.closed?
      stop_process(wait)
      drain&.join
      output&.close unless output&.closed?
    end

    record, valid_readiness, readiness_error = parse_readiness(raw, timed_out: timed_out)
    reason = protocol_error || readiness_error
    reason = 'GTK-family LoadError or NameError observed' if gtk_load_error?(log)
    loaded_features = valid_readiness ? record.fetch('loaded_features') : nil
    status = wait&.value
    result = {
      'mode'                 => mode,
      'argv'                 => argv,
      'reached_startup'      => valid_readiness,
      'verdict'              => reason ? 'fail' : 'pass',
      'failure_reason'       => reason,
      'exit_status'          => status&.exitstatus,
      'term_signal'          => status&.termsig,
      'loaded_features'      => loaded_features,
      'loaded_features_path' => loaded_features_path,
      'log_path'             => log_path,
      'result_path'          => result_path
    }
    File.binwrite(log_path, log)
    File.write(loaded_features_path, JSON.pretty_generate(loaded_features || []))
    File.write(result_path, JSON.pretty_generate(result))
    result
  end

  def self.parse_readiness(raw, timed_out:)
    return [nil, false, 'startup readiness timeout'] if timed_out
    return [nil, false, 'missing readiness record'] if raw.empty?

    record = JSON.parse(raw)
    valid = record.is_a?(Hash) && record['event'] == 'startup_complete' &&
            record['loaded_features'].is_a?(Array) && !record['loaded_features'].empty? &&
            record['loaded_features'].all? { |feature| feature.is_a?(String) }
    [record, valid, valid ? nil : 'invalid readiness record']
  rescue JSON::ParserError
    [nil, false, 'malformed readiness record']
  end

  def self.read_readiness(reader)
    raw = reader.gets.to_s
    while IO.select([reader], nil, nil, 0.01)
      chunk = reader.read_nonblock(4096, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      raw << chunk
    end
    raw
  end

  def self.gtk_load_error?(log)
    lines = log.encode('UTF-8', invalid: :replace, undef: :replace).lines
    lines.each_index.any? do |index|
      first = [index - 2, 0].max
      window = lines.slice(first, 5).join
      window.match?(ERROR_CLASS_PATTERN) && window.match?(GTK_FAMILY_PATTERN)
    end
  end

  def self.stop_process(wait)
    return unless wait

    signal_process('TERM', -wait.pid)
    wait.join(2)
    signal_process('KILL', -wait.pid)
    wait.join
  end

  def self.signal_process(signal, pid)
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  results, artifact = StartupLoadCheck.run(artifact_dir: ENV['LICH_CI_ARTIFACT_DIR'])
  puts JSON.generate('artifact' => artifact, 'results' => results)
  abort 'GTK-free startup failures' if results.any? { |result| result['verdict'] == 'fail' }
end
