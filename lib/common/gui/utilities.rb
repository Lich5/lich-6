# frozen_string_literal: true

module Lich
  module Common
    module GUI
      # Shared launcher-domain helpers retained by CLI and WebUI persistence.
      module Utilities
        # Handles file operations with error handling and backups
        # Provides a safe way to read, write, and backup files
        #
        # @param file_path [String] Path to the file
        # @param operation [Symbol] Operation to perform (:read, :write, :backup)
        # @param content [String] Content to write (for :write operation)
        # @return [String, Boolean] File content for :read, success status for others
        def self.safe_file_operation(file_path, operation, content = nil)
          case operation
          when :read
            File.read(file_path)
          when :write
            # Create backup if file exists
            safe_file_operation(file_path, :backup) if File.exist?(file_path)

            # Write content to file with secure permissions
            File.open(file_path, 'w', 0600) do |file|
              file.write(content)
            end
            true
          when :backup
            return false unless File.exist?(file_path)

            backup_file = "#{file_path}.bak"
            FileUtils.cp(file_path, backup_file)
            true
          end
        rescue StandardError => e
          Lich.log "error: Error in file operation (#{operation}): #{e.message}"
          operation == :read ? "" : false
        end

        # Handles file operations with verification to ensure data persistence
        # Provides verified file operations that confirm successful completion before returning
        # Uses flush and fsync to ensure data is written to disk before verification
        #
        # @param file_path [String] Path to the file
        # @param operation [Symbol] Operation to perform (:read, :write, :backup)
        # @param content [String] Content to write (for :write operation)
        # @return [String, Boolean] File content for :read, success status for others
        def self.verified_file_operation(file_path, operation, content = nil)
          case operation
          when :read
            File.read(file_path)
          when :write
            # Create backup if file exists
            safe_file_operation(file_path, :backup) if File.exist?(file_path)

            # Write content with forced synchronization and secure permissions
            File.open(file_path, 'w', 0600) do |file|
              file.write(content)
              file.flush    # Force write to OS buffer
              file.fsync    # Force OS to write to disk
            end

            # Verify write completed by reading back and comparing
            written_content = File.read(file_path)
            return written_content == content
          when :backup
            return false unless File.exist?(file_path)

            backup_file = "#{file_path}.bak"
            FileUtils.cp(file_path, backup_file)

            # Verify backup was created successfully
            File.exist?(backup_file) && File.size(backup_file) == File.size(file_path)
          end
        rescue StandardError => e
          Lich.log "error: Error in verified file operation (#{operation}): #{e.message}"
          operation == :read ? "" : false
        end
      end
    end
  end
end
