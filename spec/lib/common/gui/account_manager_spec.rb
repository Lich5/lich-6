# frozen_string_literal: true

require_relative '../../../login_spec_helper'

RSpec.describe Lich::Common::GUI::AccountManager do
  let(:data_dir) { "/tmp/test_data" }
  let(:username) { "test_user" }
  let(:password) { "test_password" }

  before do
    # Setup test directory and files
    FileUtils.mkdir_p(data_dir)
  end

  after do
    # Clean up test directory
    FileUtils.rm_rf(data_dir)
  end

  describe ".add_or_update_account" do
    context "when account doesn't exist" do
      it "creates a new account" do
        # Test that a new account is created with correct structure
        expect(described_class.add_or_update_account(data_dir, username, password)).to be true

        # Verify YAML file structure
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        expect(File.exist?(yaml_file)).to be true

        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts']).to have_key(username.upcase)
        expect(yaml_data['accounts'][username.upcase]['password']).to eq(password)
        expect(yaml_data['accounts'][username.upcase]['characters']).to eq([])
      end
    end

    context "when account exists" do
      before do
        # Create existing account
        described_class.add_or_update_account(data_dir, username, "old_password")
      end

      it "updates the account password" do
        # Test that the account password is updated
        expect(described_class.add_or_update_account(data_dir, username, password)).to be true

        # Verify password is updated
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts'][username.upcase]['password']).to eq(password)
      end

      it "preserves existing characters" do
        # Add a character first
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        yaml_data = YAML.load_file(yaml_file)
        yaml_data['accounts'][username.upcase]['characters'] = [{ 'char_name' => 'TestChar', 'game_code' => 'GS', 'game_name' => 'GemStone', 'frontend' => 'stormfront' }]
        File.write(yaml_file, YAML.dump(yaml_data))

        # Update password
        expect(described_class.add_or_update_account(data_dir, username, password)).to be true

        # Verify characters are preserved
        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts'][username.upcase]['characters'].size).to eq(1)
        expect(yaml_data['accounts'][username.upcase]['characters'][0]['char_name']).to eq('TestChar')
      end
    end

    context "when file operations fail" do
      it "handles YAML load errors" do
        # Create invalid YAML file
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        File.write(yaml_file, "invalid: yaml: content: - ]")

        # Should handle error and create new structure
        expect(described_class.add_or_update_account(data_dir, username, password)).to be true

        # Verify new structure was created
        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts']).to have_key(username.upcase)
      end

      it "handles file write errors" do
        # Mock file write error - updated to use verified_file_operation
        allow(Lich::Common::GUI::Utilities).to receive(:verified_file_operation).and_return(false)

        # Should return false on write error
        expect(described_class.add_or_update_account(data_dir, username, password)).to be false
      end
    end
  end

  describe ".add_character" do
    let(:character_data) do
      {
        char_name: "TestChar",
        game_code: "GS",
        game_name: "GemStone",
        frontend: "stormfront",
        custom_launch: nil,
        custom_launch_dir: nil
      }
    end

    before do
      # Create account
      described_class.add_or_update_account(data_dir, username, "password")
    end

    context "when account exists" do
      it "adds a character to the account" do
        # Test that the character is added
        result = described_class.add_character(data_dir, username, character_data)
        expect(result[:success]).to be true

        # Verify character is added
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts'][username.upcase]['characters'].size).to eq(1)
        expect(yaml_data['accounts'][username.upcase]['characters'][0]['char_name']).to eq(character_data[:char_name].capitalize)
        expect(yaml_data['accounts'][username.upcase]['characters'][0]['game_code']).to eq(character_data[:game_code])
      end

      it "adds multiple characters to the account" do
        # Add first character
        described_class.add_character(data_dir, username, character_data)

        # Add second character
        second_character = character_data.merge(char_name: "SecondChar")
        result = described_class.add_character(data_dir, username, second_character)
        expect(result[:success]).to be true

        # Verify both characters are present
        yaml_file = Lich::Common::Authentication::EntryStore.yaml_file_path(data_dir)
        yaml_data = YAML.load_file(yaml_file)
        expect(yaml_data['accounts'][username.upcase]['characters'].size).to eq(2)
        expect(yaml_data['accounts'][username.upcase]['characters'][1]['char_name']).to eq("Secondchar")
      end
    end

    context "when account doesn't exist" do
      it "returns false" do
        # Test that false is returned when account doesn't exist
        result = described_class.add_character(data_dir, "nonexistent", character_data)
        expect(result[:success]).to be false
      end
    end
  end
end
