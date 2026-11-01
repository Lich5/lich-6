# frozen_string_literal: true

require 'stringio'
require 'tmpdir'

require_relative '../../../spec_helper'
require_relative '../../../login_spec_helper'
require_relative '../../../../lib/common/cli/cli_encryption_mode_change'

RSpec.describe Lich::Common::CLI::EncryptionModeChange do
  let(:data_dir) { Dir.mktmpdir('cli-mode-change') }
  let(:entry_store) { Lich::Common::Authentication::EntryStore }

  around do |example|
    original_stdout = $stdout
    $stdout = StringIO.new
    example.run
  ensure
    $stdout = original_stdout
    FileUtils.remove_entry(data_dir)
  end

  before do
    stub_const('DATA_DIR', data_dir)
    File.write(entry_store.yaml_file_path(data_dir), YAML.dump('encryption_mode' => 'plaintext', 'accounts' => {}))
    allow(Lich).to receive(:log)
  end

  describe '.change_mode' do
    it 'hands the domain method the credential provider it must use' do
      allow(entry_store).to receive(:change_encryption_mode).and_return(true)

      expect(described_class.change_mode(:enhanced, 'synthetic-master')).to eq(0)

      expect(entry_store).to have_received(:change_encryption_mode)
        .with(data_dir, :enhanced, 'synthetic-master', manager: Lich::Common::GUI::MasterPasswordManager)
    end
  end
end
