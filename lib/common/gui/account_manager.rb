# frozen_string_literal: true

require_relative '../frontend'

module Lich
  module Common
    module GUI
      # Persists CLI account imports and character additions while preserving metadata.
      module AccountManager
        # Adds or updates an account with password and optional characters
        # Normalizes account and character names for consistent storage
        # When updating existing accounts, merges characters to preserve existing metadata (favorites, etc.)
        #
        # @param data_dir [String] Directory containing entry data
        # @param username [String] Account username (will be normalized to UPCASE)
        # @param password [String] Account password
        # @param characters [Array<Hash>] Optional array of character data hashes (will be normalized to Title case)
        #   Character hash format: { char_name:, game_code:, game_name:, frontend:, custom_launch:, custom_launch_dir: }
        # @return [Boolean] True if operation was successful
        #
        # @note For existing accounts:
        #   - Password is always updated
        #   - Characters are merged (existing preserved, new ones added if not duplicates)
        #   - Existing character metadata (favorites, custom settings) is preserved
        #   - Duplicate detection uses normalized char_name + game_code + frontend + custom_launch
        # @note For new accounts:
        #   - Account created with normalized username (UPCASE)
        #   - Characters added with normalized names (Title case)
        def self.add_or_update_account(data_dir, username, password, characters = [])
          yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)

          # Normalize username to UPCASE for consistent storage
          normalized_username = username.to_s.upcase

          # Load existing data or create new structure
          yaml_data = if File.exist?(yaml_file)
                        begin
                          YAML.load_file(yaml_file)
                        rescue StandardError => e
                          Lich.log "error: Error loading YAML entry file: #{e.message}"
                          return false
                        end
                      else
                        { 'accounts' => {} }
                      end

          # Initialize accounts hash if not present
          yaml_data['accounts'] ||= {}

          # Determine encryption mode and get master password if needed
          encryption_mode = yaml_data['encryption_mode'] || 'plaintext'
          master_password = nil
          if encryption_mode.to_sym == :enhanced
            master_password = Lich::Common::GUI::MasterPasswordManager.retrieve_master_password
            if master_password.nil?
              Lich.log "error: Enhanced mode enabled but master password not found in Keychain"
              raise StandardError, "Master password required for enhanced mode encryption"
            end
          end

          # Encrypt the password based on encryption mode
          encrypted_password = Lich::Common::Authentication::EntryStore.encrypt_password(
            password,
            mode: encryption_mode,
            account_name: normalized_username,
            master_password: master_password
          )

          return false if encrypted_password.nil?

          # Normalize character data if provided
          normalized_characters = characters.map do |char|
            {
              'char_name'         => Lich::Common::Authentication::EntryStore.normalize_character_name(char[:char_name]),
              'game_code'         => char[:game_code],
              'game_name'         => char[:game_name],
              'frontend'          => char[:frontend],
              'custom_launch'     => char[:custom_launch],
              'custom_launch_dir' => char[:custom_launch_dir]
            }
          end

          # Add or update account using normalized username
          if yaml_data['accounts'][normalized_username]
            # Update existing account password with encrypted value
            yaml_data['accounts'][normalized_username]['password'] = encrypted_password

            # Merge characters: preserve existing characters and their metadata (like favorites)
            # while adding any new characters from the provided list
            if !characters.empty?
              existing_characters = yaml_data['accounts'][normalized_username]['characters'] || []

              # Add new characters that don't already exist
              characters.each do |new_char|
                normalized_new_char_name = Lich::Common::Authentication::EntryStore.normalize_character_name(new_char[:char_name])

                # Check if character already exists (by char_name, game_code, frontend, custom_launch)
                # Including custom_launch allows multiple entries for same character with different launch configurations
                # Stored names are normalized too: older writes used a different form
                existing_char = existing_characters.find do |existing|
                  Lich::Common::Authentication::EntryStore.normalize_character_name(existing['char_name']) == normalized_new_char_name &&
                    existing['game_code'] == new_char[:game_code] &&
                    existing['frontend'] == new_char[:frontend] &&
                    existing['custom_launch'] == new_char[:custom_launch]
                end

                # Only add if character doesn't already exist
                unless existing_char
                  existing_characters << {
                    'char_name'         => normalized_new_char_name,
                    'game_code'         => new_char[:game_code],
                    'game_name'         => new_char[:game_name],
                    'frontend'          => new_char[:frontend],
                    'custom_launch'     => new_char[:custom_launch],
                    'custom_launch_dir' => new_char[:custom_launch_dir]
                  }
                end
              end

              yaml_data['accounts'][normalized_username]['characters'] = existing_characters
            end
          else
            # Create new account with normalized data and encrypted password
            yaml_data['accounts'][normalized_username] = {
              'password'   => encrypted_password,
              'characters' => normalized_characters
            }
          end

          # Save updated data with verification
          write_yaml_with_headers(yaml_file, yaml_data)
        end

        # Adds a character to an account
        # Normalizes account and character names for consistent storage
        # Prevents duplicate characters using normalized comparison
        # Returns detailed result information for user-friendly error messages
        #
        # @param data_dir [String] Directory containing entry data
        # @param username [String] Account username
        # @param character_data [Hash] Character data (char_name, game_code, game_name, frontend, etc.)
        # @return [Hash] Result hash with :success (Boolean) and :message (String) keys
        #   Success: { success: true, message: "Character added successfully" }
        #   Failure: { success: false, message: "Specific reason for failure" }
        def self.add_character(data_dir, username, character_data)
          yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)

          # Check if YAML file exists
          unless File.exist?(yaml_file)
            return { success: false, message: "No account data file found. Please add an account first." }
          end

          begin
            yaml_data = YAML.load_file(yaml_file)

            # Normalize username to UPCASE for consistent lookup
            normalized_username = username.to_s.upcase
            normalized_char_name = Lich::Common::Authentication::EntryStore.normalize_character_name(character_data[:char_name])

            if normalized_char_name.empty?
              return { success: false, message: "Character name cannot be empty." }
            end

            # Check if account exists
            unless yaml_data['accounts'] && yaml_data['accounts'][normalized_username]
              return { success: false, message: "Account '#{username}' not found. Please add the account first." }
            end

            # Initialize characters array if not present
            yaml_data['accounts'][normalized_username]['characters'] ||= []

            # Check for duplicate character using normalized comparison (both sides: older writes used a different form)
            # Including custom_launch allows multiple entries for same character with different launch configurations
            existing_character = yaml_data['accounts'][normalized_username]['characters'].find do |char|
              Lich::Common::Authentication::EntryStore.normalize_character_name(char['char_name']) == normalized_char_name &&
                char['game_code'] == character_data[:game_code] &&
                char['frontend'] == character_data[:frontend] &&
                char['custom_launch'] == character_data[:custom_launch]
            end

            # Return specific message if character already exists
            if existing_character
              return {
                success: false,
                message: "Character '#{normalized_char_name}' already exists for #{character_data[:game_code]} (#{character_data[:frontend]}) with this launch configuration. Duplicates are not allowed."
              }
            end

            # Add character data with normalized character name
            yaml_data['accounts'][normalized_username]['characters'] << {
              'char_name'         => normalized_char_name,
              'game_code'         => character_data[:game_code],
              'game_name'         => character_data[:game_name],
              'frontend'          => character_data[:frontend],
              'custom_launch'     => character_data[:custom_launch],
              'custom_launch_dir' => character_data[:custom_launch_dir]
            }

            # Save updated data with verification
            if write_yaml_with_headers(yaml_file, yaml_data)
              return { success: true, message: "Character '#{normalized_char_name}' added successfully." }
            else
              return { success: false, message: "Failed to save character data. Please check file permissions." }
            end
          rescue StandardError => e
            Lich.log "error: Error adding character: #{e.message}"
            return { success: false, message: "Error adding character: #{e.message}" }
          end
        end

        # Converts authentication response data to character format for storage
        # Validates and filters character data, transforming from authentication response
        # format (symbol keys) to storage format (symbol keys with validation)
        #
        # @param auth_data [Array] Array of character hashes from authentication
        # @param frontend [String] Selected frontend for all characters
        # @return [Array] Array of character data hashes formatted for storage
        def self.convert_auth_data_to_characters(auth_data, frontend = 'stormfront')
          characters = []
          return characters unless auth_data.is_a?(Array)

          auth_data.each do |char_data|
            # Ensure we have the required fields with symbol keys (as returned by authentication)
            next unless char_data.is_a?(Hash) &&
                        char_data.key?(:char_name) &&
                        char_data.key?(:game_name) &&
                        char_data.key?(:game_code)

            characters << {
              char_name: char_data[:char_name],
              game_code: char_data[:game_code],
              game_name: char_data[:game_name],
              frontend: frontend
            }
          end

          characters
        end

        # Writes YAML data with proper headers
        # Private helper method to maintain consistent file format
        # Ensures top-level fields (encryption_mode, master_password_validation_test) are preserved
        # Preserves encrypted passwords by ensuring they are serialized as quoted strings
        #
        # @param yaml_file [String] Path to YAML file
        # @param yaml_data [Hash] YAML data structure
        # @return [Boolean] True if write succeeded
        def self.write_yaml_with_headers(yaml_file, yaml_data)
          Lich::Common::Authentication::EntryStore.write_yaml_file(yaml_file, yaml_data, backup: true)
          true
        rescue StandardError => e
          # Exception messages can contain serialized credentials; log only safe
          # operation, destination and OS error context.
          detail = e.is_a?(SystemCallError) ? " (errno=#{e.errno})" : ''
          Lich.log "error: Could not save account data to #{yaml_file.inspect}: #{e.class}#{detail}"
          false
        end
        private_class_method :write_yaml_with_headers
      end
    end
  end
end
