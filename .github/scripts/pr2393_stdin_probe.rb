# frozen_string_literal: true

# Throwaway testbed probe for lich-5 #2393: what read_secret returns for each
# Windows stdin source. Prints byte-level results; never fails the job.
require_relative '../../spec/support/frontend_mock'
require_relative '../../spec/support/data_dir'
require_relative '../../spec/login_spec_helper'
require_relative '../../lib/common/authentication/cli_password'

mode, label = ARGV
begin
  secret = Lich::Common::Authentication::CLIPassword.read_secret('Password: ', from_stdin: mode == 'flag')
  result = "OK bytes=#{secret.bytesize} enc=#{secret.encoding} hex=#{secret.unpack1('H*')}"
rescue Lich::Common::Authentication::CLIPassword::SecretInputError => e
  result = "SecretInputError: #{e.message}"
end
puts "PROBE #{label}: #{result} (stdin.tty?=#{$stdin.tty?})"
