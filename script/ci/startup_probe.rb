# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'socket'

module LichCiStartupProbe
  module_function

  def install_fixtures!
    return unless ENV['LICH_CI_STARTUP_FIXTURES'] == '1'

    @game_server = TCPServer.new('127.0.0.1', 0)
    @game_server_thread = Thread.new do
      socket = @game_server.accept
      sleep 30
    ensure
      socket&.close
    end
    rewrite_direct_target!
    install_tracepoint!
  end

  def rewrite_direct_target!
    game_flag = ARGV.index('-g') || ARGV.index('--game')
    ARGV[game_flag + 1] = "127.0.0.1:#{@game_server.local_address.ip_port}" if game_flag
  end

  def install_tracepoint!
    @installer = TracePoint.new(:end) do |trace|
      install_cli_fixture(trace)
      install_webui_fixture(trace)
    end
    @installer.enable
  end

  def install_cli_fixture(trace)
    return unless trace.path.end_with?('/common/authentication/cli.rb')
    return unless defined?(Lich::Common::Authentication::CLI)
    return unless trace.self.equal?(Lich::Common::Authentication::CLI)

    fixture = Module.new do
      define_method(:execute) { |*_args, **_kwargs| LichCiStartupProbe.launch_data }
    end
    Lich::Common::Authentication::CLI.singleton_class.prepend(fixture)
  end

  def install_webui_fixture(trace)
    return unless trace.path.end_with?('/common/webui_launcher.rb')
    return unless defined?(Lich::Common::WebUILauncher)
    return unless trace.self.equal?(Lich::Common::WebUILauncher)

    fixture = Module.new do
      define_method(:start) { self }
      define_method(:await_launch) { LichCiStartupProbe.launch_data }
    end
    Lich::Common::WebUILauncher.prepend(fixture)
  end

  def launch_data
    client = File.expand_path('startup_fixture_client.rb', __dir__)
    command = "env -u RUBYOPT -u LICH_CI_STARTUP_FD #{RbConfig.ruby} #{client} 127.0.0.1 %port%"
    [
      'GAMECODE=GS3',
      'GAME=STORM',
      'GAMEHOST=127.0.0.1',
      "GAMEPORT=#{@game_server.local_address.ip_port}",
      'KEY=CI-STARTUP-PROBE',
      "CUSTOMLAUNCH=#{command}"
    ]
  end

  def report!
    return if @reported

    @installer&.disable
    writer = IO.for_fd(Integer(ENV.fetch('LICH_CI_STARTUP_FD')), 'w')
    writer.puts(JSON.generate('event' => 'startup_complete', 'loaded_features' => $LOADED_FEATURES.sort))
    writer.flush
    writer.close
    @reported = true
  end
end

LichCiStartupProbe.install_fixtures!
