# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../spec_helper'
require_relative '../../../login_spec_helper'
require 'common/webui_launcher/catalog'

RSpec.describe Lich::Common::WebUILauncher::Catalog, 'real entry-store integration' do
  let(:data_dir) { Dir.mktmpdir('webui-catalog') }
  let(:manager) do
    Class.new do
      def self.keychain_available? = true
      def self.retrieve_master_password = nil
    end
  end
  let(:catalog) { described_class.new(data_dir: data_dir, master_password_manager: manager) }

  before do
    File.write(File.join(data_dir, 'entry.yaml'), YAML.dump({
      'encryption_mode' => 'plaintext',
      'accounts'        => {
        'DOUG' => {
          'password'   => 'server-origin-canary',
          'characters' => [{
            'char_name' => 'Bera', 'game_code' => 'DR', 'game_name' => 'DragonRealms',
            'frontend' => 'wizard', 'is_favorite' => false,
          }],
        },
      },
    }))
  end

  after { FileUtils.remove_entry(data_dir) }

  it 'reads, sorts, mutates, persists, reloads, and removes real saved entries' do
    entry = catalog.entries.first
    expect(entry.char_name).to eq('Bera')
    expect(catalog.credential(entry.key).consume(&:dup)).to eq('server-origin-canary')

    expect(catalog.toggle_favorite(entry.key)).to be(true)
    expect(catalog.add_character('DOUG', {
      char_name: 'aldor', game_code: 'GS3', game_name: 'GemStone IV', frontend: 'stormfront',
      custom_launch: nil, custom_launch_dir: nil,
    })).to be(true)
    aldor = catalog.entries(autosort: true).find { |item| item.char_name == 'Aldor' }
    expect(catalog.update_character(aldor.key, {
      char_name: 'aldor prime', game_code: 'GS3', game_name: 'GemStone IV', frontend: 'stormfront',
      custom_launch: nil, custom_launch_dir: nil,
    })).to be(true)

    reloaded = described_class.new(data_dir: data_dir, master_password_manager: manager)
    expect(reloaded.entries.map(&:char_name)).to contain_exactly('Bera', 'Aldor Prime')
    expect(reloaded.entries.find { |item| item.char_name == 'Bera' }.favorite).to be(true)
    expect(reloaded.remove_entry(reloaded.entries.find { |item| item.char_name == 'Aldor Prime' }.key)).to be(true)
    expect(reloaded.remove_account('DOUG')).to be(true)
    expect(reloaded.entries).to be_empty
  end

  it 'reports an indeterminate favorite state when persistence fails' do
    entry = catalog.entries.first
    allow(catalog).to receive(:write_yaml).and_return(false)

    expect(catalog.toggle_favorite(entry.key)).to be_nil
  end

  describe 'master-password changes' do
    let(:current_password) { 'synthetic-current-master' }
    let(:new_password) { 'synthetic-new-master' }
    let(:entry_store) { Lich::Common::Authentication::EntryStore }
    let(:manager) do
      double('master password manager', validate_master_password: true,
                                       create_validation_test: 'new-validation', store_master_password: true)
    end
    let(:plaintexts) { [] }
    let(:path) { File.join(data_dir, 'entry.yaml') }

    before do
      data = YAML.load_file(path)
      data['encryption_mode'] = 'enhanced'
      data['master_password_validation_test'] = 'old-validation'
      data['accounts']['OTHER'] = { 'password' => 'second-account-canary', 'characters' => [] }
      data['accounts'].each do |name, account|
        account['password'] = entry_store.encrypt_password(
          account['password'], mode: :enhanced, account_name: name, master_password: current_password
        )
      end
      File.write(path, YAML.dump(data))
      allow(entry_store).to receive(:decrypt_password).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { |plaintext| plaintexts << plaintext }
      end
    end

    it 'persists re-encrypted accounts and clears each temporary plaintext' do
      expect(catalog.change_master_password(current_password, new_password)).to be(true)
      expect(plaintexts.size).to eq(2)
      expect(plaintexts).to all(eq(''))
      saved = YAML.load_file(path)
      expect(saved['master_password_validation_test']).to eq('new-validation')
      expect(manager).to have_received(:store_master_password).with(new_password).once
      expected = { 'DOUG' => 'server-origin-canary', 'OTHER' => 'second-account-canary' }
      expected.each do |name, password|
        expect(entry_store.decrypt_password(saved['accounts'][name]['password'], mode: :enhanced,
                                                                               account_name: name, master_password: new_password)).to eq(password)
      end
    end

    it 'returns false without changing persisted data when validation fails' do
      allow(manager).to receive(:validate_master_password).and_return(false)
      before = File.binread(path)

      expect(catalog.change_master_password(current_password, new_password)).to be(false)
      expect(File.binread(path)).to eq(before)
      expect(manager).not_to have_received(:store_master_password)
      expect(plaintexts).to be_empty
    end

    it 'clears temporary plaintext and preserves the original encryption exception' do
      allow(entry_store).to receive(:encrypt_password).and_raise(IOError, 'synthetic encryption failure')
      before = File.binread(path)

      expect { catalog.change_master_password(current_password, new_password) }
        .to raise_error(IOError, 'synthetic encryption failure')
      expect(plaintexts).to eq([''])
      expect(File.binread(path)).to eq(before)
      expect(manager).not_to have_received(:store_master_password)
    end

    it 'restores the previous keychain value when persistence fails' do
      allow(catalog).to receive(:write_yaml).and_return(false)
      expect(manager).to receive(:store_master_password).with(new_password).ordered.and_return(true)
      expect(manager).to receive(:store_master_password).with(current_password).ordered.and_return(true)
      before = File.binread(path)

      expect(catalog.change_master_password(current_password, new_password)).to be(false)
      expect(File.binread(path)).to eq(before)
      expect(plaintexts).to all(eq(''))
    end
  end

  describe 'legacy entries without a YAML catalog' do
    let(:legacy_entries) do
      %w[Aldor Bera].map do |name|
        { user_id: 'DOUG', password: 'synthetic-legacy-password', char_name: name,
          game_code: 'GS3', game_name: 'GemStone IV', frontend: 'stormfront' }
      end
    end
    let(:legacy_path) { File.join(data_dir, 'entry.dat') }
    let(:yaml_path) { File.join(data_dir, 'entry.yaml') }

    before do
      File.unlink(yaml_path)
      File.binwrite(legacy_path, [Marshal.dump(legacy_entries)].pack('m'))
    end

    %i[manual account].each do |kind|
      it "refuses a partial #{kind} save while retaining every legacy entry" do
        original = File.binread(legacy_path)
        expect do
          if kind == :manual
            catalog.upsert_manual_entry(legacy_entries.first, 'replacement-password')
          else
            catalog.add_or_update_account('OTHER', 'replacement-password', [legacy_entries.first], frontend: 'stormfront')
          end
        end.to raise_error(described_class::LegacyConversionRequired)

        expect(File.exist?(yaml_path)).to be(false)
        expect(File.binread(legacy_path)).to eq(original)
        expect(catalog.entries.map(&:char_name)).to contain_exactly('Aldor', 'Bera')
        expect(catalog.legacy_conversion_needed?).to be(true)
      end
    end

    %i[plaintext standard enhanced].each do |mode|
      it "migrates real legacy data through the catalog in #{mode} mode" do
        master = mode == :enhanced ? 'synthetic-migration-master' : nil
        manager = Lich::Common::GUI::MasterPasswordManager
        expect(manager).not_to receive(:retrieve_master_password)
        expect(manager).not_to receive(:store_master_password)

        expect(catalog.migrate_legacy(mode, master_password: master)).to be(true)

        saved = YAML.safe_load_file(yaml_path)
        expect(saved['encryption_mode']).to eq(mode.to_s)
        if master
          expect(manager.validate_master_password(master, saved['master_password_validation_test'])).to be(true)
        end
        catalog.entries.each do |entry|
          expect(catalog.credential(entry.key, master_password: master).consume(&:dup)).to eq('synthetic-legacy-password')
        end
        expect(catalog.entries.map(&:char_name)).to contain_exactly('Aldor', 'Bera')
      end
    end
  end

  it 'rejects a legacy payload containing nested objects' do
    legacy_dir = Dir.mktmpdir('webui-legacy-catalog')
    payload = [{ 'user_id' => 'DOUG', 'password' => { 'nested' => 'not allowed' } }]
    File.binwrite(File.join(legacy_dir, 'entry.dat'), [Marshal.dump(payload)].pack('m'))
    legacy_catalog = described_class.new(data_dir: legacy_dir, master_password_manager: manager)

    expect(legacy_catalog.entries).to be_empty
  ensure
    FileUtils.remove_entry(legacy_dir) if legacy_dir && File.directory?(legacy_dir)
  end
end
