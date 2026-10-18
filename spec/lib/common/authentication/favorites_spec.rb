# frozen_string_literal: true

# Spec coverage for favorites functionality in EntryStore
# Covers PR 1063 YAML requirements for favorites metadata support

require 'rspec'
require 'fileutils'
require 'tmpdir'
require 'yaml'
require_relative '../../../login_spec_helper'
require_relative '../../../../lib/common/authentication/entry_store'

RSpec.describe 'EntryStore Favorites' do
  let(:temp_dir) { Dir.mktmpdir }
  let(:data_dir) { temp_dir }
  let(:yaml_file) { File.join(data_dir, 'entry.yaml') }

  # Sample YAML data structure
  let(:sample_yaml_data) do
    {
      'encryption_mode' => 'plaintext',
      'accounts'        => {
        'TESTUSER'    => {
          'password'   => 'test_password',
          'characters' => [
            {
              'char_name'   => 'TestChar1',
              'game_code'   => 'GS3',
              'game_name'   => 'GemStone IV',
              'frontend'    => 'stormfront',
              'is_favorite' => false
            },
            {
              'char_name'   => 'TestChar2',
              'game_code'   => 'DR',
              'game_name'   => 'DragonRealms',
              'frontend'    => 'wizard',
              'is_favorite' => false
            }
          ]
        },
        'ANOTHERUSER' => {
          'password'   => 'another_password',
          'characters' => [
            {
              'char_name'      => 'AnotherChar',
              'game_code'      => 'GS3',
              'game_name'      => 'GemStone IV',
              'frontend'       => 'stormfront',
              'is_favorite'    => true,
              'favorite_order' => 1,
              'favorite_added' => '2026-01-01 12:00:00'
            }
          ]
        }
      }
    }
  end

  before do
    # Stub Utilities for safe_file_operation
    allow(Lich::Common::GUI::Utilities).to receive(:safe_file_operation) do |path, operation, content|
      if operation == :write
        File.write(path, content)
        true
      end
    end
  end

  after { FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir) }

  describe '.migrate_to_favorites_format' do
    it 'adds is_favorite field to characters without it' do
      yaml_data = {
        'accounts' => {
          'TESTUSER' => {
            'characters' => [
              { 'char_name' => 'NoFavoriteField' }
            ]
          }
        }
      }

      result = Lich::Common::Authentication::EntryStore.migrate_to_favorites_format(yaml_data)

      character = result['accounts']['TESTUSER']['characters'].first
      expect(character['is_favorite']).to eq(false)
    end

    it 'preserves existing is_favorite value if true' do
      yaml_data = {
        'accounts' => {
          'TESTUSER' => {
            'characters' => [
              { 'char_name' => 'ExistingFavorite', 'is_favorite' => true, 'favorite_order' => 1 }
            ]
          }
        }
      }

      result = Lich::Common::Authentication::EntryStore.migrate_to_favorites_format(yaml_data)

      character = result['accounts']['TESTUSER']['characters'].first
      expect(character['is_favorite']).to eq(true)
      expect(character['favorite_order']).to eq(1)
    end

    it 'handles nil yaml_data gracefully' do
      result = Lich::Common::Authentication::EntryStore.migrate_to_favorites_format(nil)
      expect(result).to be_nil
    end

    it 'handles empty accounts gracefully' do
      yaml_data = { 'accounts' => {} }
      result = Lich::Common::Authentication::EntryStore.migrate_to_favorites_format(yaml_data)
      expect(result['accounts']).to eq({})
    end

    it 'handles missing accounts key' do
      yaml_data = { 'encryption_mode' => 'plaintext' }
      result = Lich::Common::Authentication::EntryStore.migrate_to_favorites_format(yaml_data)
      expect(result).to eq(yaml_data)
    end
  end

  describe '.sort_entries_with_favorites' do
    let(:entries) do
      [
        { char_name: 'ZChar', user_id: 'ZUSER', game_name: 'GemStone IV', is_favorite: false },
        { char_name: 'AChar', user_id: 'AUSER', game_name: 'DragonRealms', is_favorite: true, favorite_order: 2 },
        { char_name: 'BChar', user_id: 'BUSER', game_name: 'GemStone IV', is_favorite: false },
        { char_name: 'FavChar', user_id: 'FAVUSER', game_name: 'GemStone IV', is_favorite: true, favorite_order: 1 }
      ]
    end

    context 'when autosort is enabled' do
      it 'places favorites first, sorted by favorite_order' do
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(entries, true)

        expect(result[0][:char_name]).to eq('FavChar')  # favorite_order 1
        expect(result[1][:char_name]).to eq('AChar')    # favorite_order 2
      end

      it 'sorts non-favorites by account name, game name, char name' do
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(entries, true)

        # Non-favorites should come after favorites
        non_favorites = result[2..]
        expect(non_favorites[0][:user_id]).to eq('BUSER')
        expect(non_favorites[1][:user_id]).to eq('ZUSER')
      end

      it 'handles entries with nil favorite_order' do
        entries_with_nil = entries + [
          { char_name: 'NilOrder', user_id: 'NILUSER', game_name: 'GS', is_favorite: true, favorite_order: nil }
        ]

        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(entries_with_nil, true)

        # nil favorite_order should sort to end of favorites (999)
        favorites = result.select { |e| e[:is_favorite] }
        expect(favorites.last[:char_name]).to eq('NilOrder')
      end
    end

    context 'when autosort is disabled' do
      it 'returns entries in original order' do
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(entries, false)

        expect(result).to eq(entries)
      end
    end

    context 'edge cases' do
      it 'handles empty array' do
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites([], true)
        expect(result).to eq([])
      end

      it 'handles array with only favorites' do
        favorites_only = entries.select { |e| e[:is_favorite] }
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(favorites_only, true)

        expect(result.length).to eq(2)
        expect(result.first[:favorite_order]).to eq(1)
      end

      it 'handles array with no favorites' do
        non_favorites = entries.reject { |e| e[:is_favorite] }
        result = Lich::Common::Authentication::EntryStore.sort_entries_with_favorites(non_favorites, true)

        expect(result.length).to eq(2)
        # Should be sorted alphabetically by user_id
        expect(result.first[:user_id]).to eq('BUSER')
      end
    end
  end
end
