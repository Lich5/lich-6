# frozen_string_literal: true

module Lich
  module Common
    module GUI
      # Reads legacy entry.dat data for CLI and native launcher migration.
      module State
        # Loads saved entry data from file
        # Reads and deserializes entry data from the entry.dat file
        #
        # @param data_dir [String] Directory containing entry data
        # @param autosort_state [Boolean] Whether to use auto-sorting
        # @return [Array] Array of saved login entries
        def self.load_saved_entries(data_dir, autosort_state)
          if File.exist?(File.join(data_dir, "entry.dat"))
            File.open(File.join(data_dir, "entry.dat"), 'r') { |file|
              begin
                if autosort_state
                  # Sort in list by instance name, account name, and then character name
                  Marshal.load(file.read.unpack('m').first).sort do |a, b|
                    [a[:game_name], a[:user_id], a[:char_name]] <=> [b[:game_name], b[:user_id], b[:char_name]]
                  end
                else
                  # Sort in list by account name, and then character name (old Lich 4)
                  Marshal.load(file.read.unpack('m').first).sort do |a, b|
                    [a[:user_id].downcase, a[:char_name]] <=> [b[:user_id].downcase, b[:char_name]]
                  end
                end
              rescue
                Array.new
              end
            }
          else
            Lich.log "Info: No entry.dat file detected, probable new installation."
            Array.new
          end
        end
      end
    end
  end
end
