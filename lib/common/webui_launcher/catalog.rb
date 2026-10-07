# frozen_string_literal: true

require 'openssl'
require 'yaml'
require 'json'
require_relative '../authentication/entry_store'
require_relative '../gui/master_password_manager'
require_relative '../../webui/sensitive_value'

module Lich
  module Common
    class WebUILauncher
      # Reads and mutates launcher data without retaining decrypted credentials.
      class Catalog
        SETTING_WRITERS = {
          dark_theme: :track_dark_mode=,
          tab_layout: :track_layout_state=,
          autosort: :track_autosort_state=,
          persistent: :track_persistent_launcher_mode=,
        }.freeze

        class MasterPasswordRequired < StandardError; end
        class LegacyConversionRequired < StandardError; end
        class InvalidCatalogError < StandardError; end

        INVALID_CATALOG_NOTICE = 'Saved entries are unreadable. Repair or restore entry.yaml, then refresh. ' \
                                 'Manual Entry remains available; catalog changes are disabled.'

        LEGACY_CONVERSION_NOTICE = 'Legacy saved entries must be converted before saving changes. ' \
                                   'Close the launcher and run ruby lich.rbw --convert-entries MODE ' \
                                   'with plaintext, standard, or enhanced, then reopen it.'

        Entry = Data.define(
          :key, :user_id, :char_name, :game_code, :game_name, :frontend,
          :custom_launch, :custom_launch_dir, :favorite, :favorite_order
        )

        attr_reader :data_dir

        def initialize(data_dir:, entry_store: Authentication::EntryStore,
                       master_password_manager: GUI::MasterPasswordManager)
          @data_dir = data_dir
          @entry_store = entry_store
          @master_password_manager = master_password_manager
          @mutex = Mutex.new
        end

        # Reads password-free entries whose keys remain stable across unrelated edits.
        # @param autosort [Boolean] apply the user's display sorting preference
        # @return [Array<Entry>] saved configurations in display order
        def entries(autosort: false)
          @mutex.synchronize do
            normalized = source_entries.map do |entry|
              entry.merge(user_id: entry[:user_id].to_s, char_name: entry[:char_name].to_s,
                          game_name: entry[:game_name].to_s, is_favorite: entry[:is_favorite] == true)
            end
            @entry_store.sort_entries_with_favorites(normalized, autosort).map do |entry|
              Entry.new(
                entry.fetch(:key), entry.fetch(:user_id).to_s, entry.fetch(:char_name).to_s,
                entry.fetch(:game_code).to_s, entry[:game_name].to_s, entry[:frontend].to_s,
                entry[:custom_launch], entry[:custom_launch_dir], entry[:is_favorite] == true,
                entry[:favorite_order]
              )
            end
          end
        end

        def accounts
          @mutex.synchronize do
            file = @entry_store.yaml_file_path(data_dir)
            next entries_without_lock.map { |entry| entry[:user_id] }.uniq unless File.exist?(file)

            yaml_data.fetch('accounts', {}).keys
          end
        end

        def update_launcher_setting(setting, value)
          Lich.public_send(SETTING_WRITERS.fetch(setting), value)
          true
        end

        def legacy_conversion_needed?
          !File.exist?(@entry_store.yaml_file_path(data_dir)) && File.exist?(File.join(data_dir, 'entry.dat'))
        end

        def encryption_mode
          @mutex.synchronize { yaml_data.fetch('encryption_mode', 'plaintext').to_sym }
        end

        def validation_test
          @mutex.synchronize { yaml_data['master_password_validation_test'] }
        end

        def enhanced_encryption_available?
          @master_password_manager.keychain_available?
        end

        # The returned carrier is the first plaintext representation produced by
        # this boundary and never enters launcher state or a page tree.
        def credential(entry_key, master_password: nil)
          @mutex.synchronize do
            metadata = entries_without_lock.find { |entry| entry[:key] == entry_key }
            raise KeyError, 'saved entry no longer exists' unless metadata

            raw, mode = raw_credential(metadata)
            if mode == :enhanced && master_password.nil?
              master_password = @master_password_manager.retrieve_master_password
              raise MasterPasswordRequired, 'master password is required' if master_password.to_s.empty?
            end
            plaintext = @entry_store.decrypt_password(
              raw, mode: mode, account_name: metadata[:user_id], master_password: master_password
            )
            Lich::WebUI::SensitiveValue.server(plaintext)
          ensure
            plaintext&.replace("\0" * plaintext.bytesize)&.clear if plaintext.is_a?(String) && !plaintext.frozen?
          end
        end

        def validate_master_password(password)
          test = validation_test
          return false unless @master_password_manager.validate_master_password(password, test)

          @master_password_manager.store_master_password(password)
          true
        end

        def upsert_manual_entry(entry, password)
          @mutex.synchronize do
            data = writable_yaml_data
            account = entry.fetch(:user_id).to_s.upcase
            mode = data.fetch('encryption_mode', 'plaintext').to_sym
            master = mode == :enhanced ? @master_password_manager.retrieve_master_password : nil
            raise MasterPasswordRequired, 'master password is required' if mode == :enhanced && master.to_s.empty?

            account_data = (data['accounts'][account] ||= { 'characters' => [] })
            account_data['password'] = @entry_store.encrypt_password(
              password, mode: mode, account_name: account, master_password: master
            )
            characters = (account_data['characters'] ||= [])
            character = characters.find do |candidate|
              candidate['char_name'].to_s.casecmp?(entry.fetch(:char_name).to_s) &&
                candidate['game_code'].to_s == entry.fetch(:game_code).to_s &&
                candidate['frontend'].to_s == entry.fetch(:frontend).to_s &&
                candidate['custom_launch'].to_s == entry[:custom_launch].to_s
            end
            character ||= {}.tap { |candidate| characters << candidate }
            character.merge!(
              'char_name'         => normalize_character_name(entry.fetch(:char_name)),
              'game_code'         => entry.fetch(:game_code).to_s,
              'game_name'         => entry[:game_name].to_s,
              'frontend'          => entry.fetch(:frontend).to_s,
              'custom_launch'     => entry[:custom_launch],
              'custom_launch_dir' => entry[:custom_launch_dir]
            )
            write_yaml(data)
          end
        end

        def add_or_update_account(account, password, characters, frontend:)
          @mutex.synchronize do
            data = writable_yaml_data
            name = account.to_s.upcase
            mode = data.fetch('encryption_mode', 'plaintext').to_sym
            master = mode == :enhanced ? @master_password_manager.retrieve_master_password : nil
            raise MasterPasswordRequired, 'master password is required' if mode == :enhanced && master.to_s.empty?
            account_data = (data['accounts'][name] ||= { 'characters' => [] })
            account_data['password'] = @entry_store.encrypt_password(
              password, mode: mode, account_name: name, master_password: master
            )
            existing = account_data['characters'] ||= []
            characters.each do |character|
              next if existing.any? do |candidate|
                candidate['char_name'].to_s.casecmp?(character.fetch(:char_name).to_s) &&
                candidate['game_code'].to_s == character.fetch(:game_code).to_s &&
                candidate['frontend'].to_s == frontend.to_s
              end

              existing << {
                'char_name' => normalize_character_name(character.fetch(:char_name)),
                'game_code' => character.fetch(:game_code).to_s,
                'game_name' => character[:game_name].to_s,
                'frontend'  => frontend.to_s,
              }
            end
            write_yaml(data)
          end
        end

        def remove_account(account)
          @mutex.synchronize do
            data = writable_yaml_data
            removed = data['accounts'].delete(account.to_s.upcase)
            removed ? write_yaml(data) : false
          end
        end

        def add_character(account, character)
          @mutex.synchronize do
            data = writable_yaml_data
            account_data = data.fetch('accounts', {})[account.to_s.upcase]
            return false unless account_data

            characters = account_data['characters'] ||= []
            duplicate = characters.any? do |candidate|
              candidate['char_name'].to_s.casecmp?(character.fetch(:char_name).to_s) &&
                candidate['game_code'].to_s == character.fetch(:game_code).to_s &&
                candidate['frontend'].to_s == character.fetch(:frontend).to_s &&
                candidate['custom_launch'].to_s == character[:custom_launch].to_s
            end
            return false if duplicate

            characters << {
              'char_name'         => normalize_character_name(character.fetch(:char_name)),
              'game_code'         => character.fetch(:game_code).to_s,
              'game_name'         => character.fetch(:game_name).to_s,
              'frontend'          => character.fetch(:frontend).to_s,
              'custom_launch'     => character[:custom_launch],
              'custom_launch_dir' => character[:custom_launch_dir],
            }
            write_yaml(data)
          end
        end

        def update_character(entry_key, character)
          @mutex.synchronize do
            metadata = entries_without_lock.find { |entry| entry[:key] == entry_key }
            return false unless metadata

            data = writable_yaml_data
            account = data.fetch('accounts', {})[metadata[:user_id]]
            current = account&.fetch('characters', [])&.find { |candidate| character_match?(candidate, metadata) }
            return false unless current

            current.merge!(
              'char_name'         => normalize_character_name(character.fetch(:char_name)),
              'game_code'         => character.fetch(:game_code).to_s,
              'game_name'         => character.fetch(:game_name).to_s,
              'frontend'          => character.fetch(:frontend).to_s,
              'custom_launch'     => character[:custom_launch],
              'custom_launch_dir' => character[:custom_launch_dir]
            )
            write_yaml(data)
          end
        end

        def change_account_password(account, current_password, new_password)
          @mutex.synchronize do
            data = writable_yaml_data
            name = account.to_s.upcase
            account_data = data.fetch('accounts', {})[name]
            return false unless account_data

            mode = data.fetch('encryption_mode', 'plaintext').to_sym
            master = mode == :enhanced ? @master_password_manager.retrieve_master_password : nil
            plaintext = @entry_store.decrypt_password(
              account_data.fetch('password').to_s, mode: mode, account_name: name, master_password: master
            )
            return false unless secure_equal?(plaintext, current_password)

            account_data['password'] = @entry_store.encrypt_password(
              new_password, mode: mode, account_name: name, master_password: master
            )
            write_yaml(data)
          ensure
            scrub!(plaintext)
          end
        end

        def remove_entry(entry_key)
          @mutex.synchronize do
            metadata = entries_without_lock.find { |entry| entry[:key] == entry_key }
            return false unless metadata

            data = writable_yaml_data
            account = data.fetch('accounts', {})[metadata[:user_id]]
            return false unless account

            characters = account.fetch('characters', [])
            before = characters.length
            characters.reject! { |candidate| character_match?(candidate, metadata) }
            return false if before == characters.length

            write_yaml(data)
          end
        end

        def toggle_favorite(entry_key)
          @mutex.synchronize do
            metadata = entries_without_lock.find { |entry| entry[:key] == entry_key }
            return false unless metadata

            data = writable_yaml_data
            account = data.fetch('accounts', {})[metadata[:user_id]]
            character = account&.fetch('characters', [])&.find { |candidate| character_match?(candidate, metadata) }
            return false unless character

            favorite = character['is_favorite'] != true
            character['is_favorite'] = favorite
            if favorite
              character['favorite_order'] = next_favorite_order(data)
              character['favorite_added'] = Time.now.to_s
            else
              character.delete('favorite_order')
              character.delete('favorite_added')
              normalize_favorite_order(data)
            end
            write_yaml(data) ? favorite : nil
          end
        end

        # Refuses mode changes while saved data is unreadable or requires migration.
        # @param mode [Symbol] selected encryption mode
        # @param master_password [String, nil] confirmed password for Enhanced mode
        # @return [Boolean] whether persistence succeeded
        def change_encryption_mode(mode, master_password: nil)
          @mutex.synchronize do
            writable_yaml_data
            @entry_store.change_encryption_mode(data_dir, mode.to_sym, master_password)
          end
        end

        def migrate_legacy(mode, master_password: nil)
          @entry_store.migrate_from_legacy(
            data_dir, encryption_mode: mode.to_sym, master_password: master_password
          )
        end

        def change_master_password(current_password, new_password)
          @mutex.synchronize do
            data = writable_yaml_data
            return false unless data.fetch('encryption_mode', 'plaintext').to_sym == :enhanced
            return false unless @master_password_manager.validate_master_password(
              current_password, data['master_password_validation_test']
            )

            data.fetch('accounts', {}).each do |name, account_data|
              plaintext = @entry_store.decrypt_password(
                account_data.fetch('password').to_s, mode: :enhanced,
                account_name: name, master_password: current_password
              )
              account_data['password'] = @entry_store.encrypt_password(
                plaintext, mode: :enhanced, account_name: name, master_password: new_password
              )
            ensure
              scrub!(plaintext)
            end
            data['master_password_validation_test'] = @master_password_manager.create_validation_test(new_password)
            return false unless @master_password_manager.store_master_password(new_password)

            written = write_yaml(data)
            @master_password_manager.store_master_password(current_password) unless written
            written
          end
        end

        private

        # Omits credential material while preserving configuration identity.
        # @api private
        # @return [Array<Hash>] metadata with stable keys
        def source_entries
          raw_entries = entries_without_lock
          raw_entries.map { |entry| entry.except(:password, :encryption_mode) }
        ensure
          raw_entries&.each do |entry|
            password = entry[:password]
            password.replace("\0" * password.bytesize).clear if password.is_a?(String) && !password.frozen?
          end
        end

        # Reads persisted entries under the caller's catalog lock.
        # @api private
        # @return [Array<Hash>] entries including credential data for internal use
        def entries_without_lock
          file = @entry_store.yaml_file_path(data_dir)
          if File.exist?(file)
            data = yaml_data
            mode = data.fetch('encryption_mode', 'plaintext').to_sym
            raw = data.fetch('accounts', {}).flat_map do |account, account_data|
              account_data.fetch('characters', []).map do |character|
                {
                  user_id: account, password: account_data['password'],
                  encryption_mode: mode, char_name: character['char_name'], game_code: character['game_code'],
                  game_name: character['game_name'], frontend: character['frontend'],
                  custom_launch: character['custom_launch'], custom_launch_dir: character['custom_launch_dir'],
                  is_favorite: character['is_favorite'], favorite_order: character['favorite_order'],
                }
              end
            end
            with_entry_keys(raw)
          else
            legacy_entries
          end
        end

        # Reads supported legacy scalars and assigns the same identities as YAML.
        # @api private
        # @return [Array<Hash>] legacy entries, or an empty list for invalid data
        def legacy_entries
          file = File.join(data_dir, 'entry.dat')
          return [] unless File.exist?(file)

          decoded = File.open(file, 'rb') { |io| Marshal.load(io.read.unpack1('m')) }
          return [] unless decoded.is_a?(Array) && decoded.all? { |entry| valid_legacy_entry?(entry) }

          with_entry_keys(decoded.map { |entry| entry.transform_keys(&:to_sym).merge(encryption_mode: :plaintext) })
        rescue StandardError => error
          Lich.log("error: unable to read legacy launcher entries: #{error.class}: #{error.message}") if Lich.respond_to?(:log)
          []
        end

        # Encodes the existing character-match tuple without delimiter ambiguity.
        # Names, frontend and launch command define a configuration; passwords,
        # favorites and list positions do not. This is identity, not authorization.
        # @api private
        # @param entry [Hash] symbol-keyed saved-entry metadata
        # @return [String] deterministic opaque configuration key
        def entry_key(entry)
          identity = %i[user_id char_name game_code frontend custom_launch].map { |field| entry[field].to_s }
          "entry-#{OpenSSL::Digest::SHA256.hexdigest(JSON.generate(identity))}"
        end

        # Keeps legacy duplicate configurations renderable without using global positions.
        # Only indistinguishable identity tuples receive an occurrence suffix; unrelated
        # removals or reordering cannot rename another configuration. Existing mutation
        # rules for duplicate tuples remain unchanged.
        # @api private
        # @param entries [Array<Hash>] saved records in their existing order
        # @return [Array<Hash>] records with unique presentation keys
        def with_entry_keys(entries)
          occurrences = Hash.new(0)
          entries.map do |entry|
            key = entry_key(entry)
            occurrence = occurrences[key]
            occurrences[key] += 1
            entry.merge(key: occurrence.zero? ? key : "#{key}-#{occurrence}")
          end
        end

        def raw_credential(metadata)
          [metadata.fetch(:password).to_s, metadata.fetch(:encryption_mode).to_sym]
        end

        def writable_yaml_data
          # A partial YAML catalog would hide every remaining entry.dat record
          # and also prevent the existing CLI conversion from running.
          raise LegacyConversionRequired, LEGACY_CONVERSION_NOTICE if legacy_conversion_needed?

          data = yaml_data
          data['accounts'] ||= {}
          data['encryption_mode'] ||= 'plaintext'
          data
        end

        # Reads saved state without treating a damaged file as an empty writable catalog.
        # @return [Hash] parsed account data, or defaults for an absent file or nil document
        # @raise [InvalidCatalogError] for unreadable YAML or incompatible container shapes
        # @api private
        def yaml_data
          file = @entry_store.yaml_file_path(data_dir)
          return { 'accounts' => {}, 'encryption_mode' => 'plaintext' } unless File.exist?(file)

          data = YAML.safe_load_file(file, permitted_classes: [Symbol])
          data = { 'accounts' => {}, 'encryption_mode' => 'plaintext' } if data.nil?
          raise InvalidCatalogError, INVALID_CATALOG_NOTICE unless valid_catalog?(data)

          data
        rescue Psych::Exception, SystemCallError, IOError
          raise InvalidCatalogError, INVALID_CATALOG_NOTICE
        end

        # Checks the containers and sort fields consumed by catalog operations.
        # @param data [Object] parsed YAML document
        # @return [Boolean] whether account iteration and sorting are safe
        # @api private
        def valid_catalog?(data)
          return false unless data.is_a?(Hash) && data.fetch('accounts', {}).is_a?(Hash)
          return false unless %w[plaintext standard enhanced].include?(data.fetch('encryption_mode', 'plaintext').to_s)

          data.fetch('accounts', {}).all? do |name, account|
            name.is_a?(String) && account.is_a?(Hash) && account.fetch('characters', []).is_a?(Array) &&
              account.fetch('characters', []).all? do |character|
                character.is_a?(Hash) && (character['favorite_order'].nil? || character['favorite_order'].is_a?(Integer))
              end
          end
        end

        def write_yaml(data)
          @entry_store.write_yaml_file(@entry_store.yaml_file_path(data_dir), data)
          true
        rescue StandardError => error
          Lich.log("error: unable to persist launcher catalog: #{error.class}: #{error.message}") if Lich.respond_to?(:log)
          false
        end

        def character_match?(candidate, metadata)
          candidate['char_name'].to_s == metadata[:char_name].to_s &&
            candidate['game_code'].to_s == metadata[:game_code].to_s &&
            candidate['frontend'].to_s == metadata[:frontend].to_s &&
            candidate['custom_launch'].to_s == metadata[:custom_launch].to_s
        end

        def normalize_character_name(value)
          value.to_s.strip.split.map(&:capitalize).join(' ')
        end

        def valid_legacy_entry?(entry)
          return false unless entry.is_a?(Hash)

          scalar = ->(value) { value.nil? || value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric) || value == true || value == false }
          entry.all? { |key, value| scalar.call(key) && scalar.call(value) }
        end

        def next_favorite_order(data)
          orders = data.fetch('accounts', {}).values.flat_map do |account|
            account.fetch('characters', []).filter_map { |character| character['favorite_order'] }
          end
          orders.map(&:to_i).max.to_i + 1
        end

        def normalize_favorite_order(data)
          favorites = data.fetch('accounts', {}).values.flat_map do |account|
            account.fetch('characters', []).select { |character| character['is_favorite'] == true }
          end
          favorites.sort_by { |character| character['favorite_order'].to_i }
                   .each_with_index { |character, index| character['favorite_order'] = index + 1 }
        end

        def secure_equal?(left, right)
          left = left.to_s
          right = right.to_s
          left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
        end

        def scrub!(value)
          value.replace("\0" * value.bytesize).clear if value.is_a?(String) && !value.frozen?
        end
      end
    end
  end
end
