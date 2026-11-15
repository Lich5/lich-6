# Loads the real CLIPassword the way the specs do, then reads a secret from
# the console exactly as `lich --add-account ACCOUNT` does.
require 'rspec'
require_relative '../spec/spec_helper'
require_relative '../spec/login_spec_helper'
require_relative '../lib/common/authentication/cli_password'

# Mirror lib/init.rb: by the time CLI commands run, $stderr is the debug log.
$stderr = File.open(File.join(__dir__, 'probe-stderr.log'), 'w')
if ENV['PROBE_DELAY']
  # Gives the driver a window to type before the prompt, like a slow startup.
  $stdout.puts 'READY'
  $stdout.flush
  sleep Float(ENV['PROBE_DELAY'])
end
if ENV['PROBE_NO_IFLUSH']
  # Control: without the flush, the early line must be what gets read.
  require 'io/console'
  def $stdin.iflush; end
end
begin
  s = Lich::Common::Authentication::CLIPassword.read_secret('Password: ', from_stdin: false)
  $stdout.puts "RESULT len=#{s.length} exact=#{s == '  typed SECRET '}"
rescue Lich::Common::Authentication::CLIPassword::SecretInputError => e
  $stdout.puts "SECRETERROR #{e.message}"
end
$stdout.puts 'PROBE-DONE'
$stdout.flush
sleep 2
