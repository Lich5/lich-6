# Reads a --password-stdin line through the real CLIPassword and reports the
# bytes it got, compared with EXPECT_HEX (the password's UTF-8 bytes).
require 'rspec'
require_relative '../spec/spec_helper'
require_relative '../spec/login_spec_helper'
require_relative '../lib/common/authentication/cli_password'

$stderr = File.open(File.join(__dir__, 'probe-stderr.log'), 'w')
begin
  s = Lich::Common::Authentication::CLIPassword.read_secret('Password: ', from_stdin: true)
  got = s.b.unpack1('H*')
  $stdout.puts "PIPE got=#{got} expect=#{ENV.fetch('EXPECT_HEX')} exact=#{got == ENV.fetch('EXPECT_HEX')}"
rescue Lich::Common::Authentication::CLIPassword::SecretInputError => e
  $stdout.puts "PIPE SECRETERROR #{e.message}"
end
