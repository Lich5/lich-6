# frozen_string_literal: true

require 'fileutils'
require 'yaml'

# Authentication and native-launcher test support. This file intentionally
# defines no graphical toolkit constants.
module Lich
  def self.log(_message); end unless respond_to?(:log)
  def self.track_autosort_state; false; end unless respond_to?(:track_autosort_state)
  def self.track_layout_state; false; end unless respond_to?(:track_layout_state)
  def self.track_dark_mode; false; end unless respond_to?(:track_dark_mode)
  def self.track_persistent_launcher_mode; false; end unless respond_to?(:track_persistent_launcher_mode)

  module Util
    def self.install_gem_requirements(*)
      require 'ffi'
      require 'os'
      true
    end unless respond_to?(:install_gem_requirements)
  end
end

module Lich
  module Common
    module Authentication
      module EAccess
        def self.auth(_options = {})
          {
            'key' => 'test_key', 'server' => 'test.example.com', 'port' => '8080',
            'gamefile' => 'STORM.EXE', 'game' => 'STORM', 'fullgamename' => 'StormFront'
          }
        end unless respond_to?(:auth)
      end
    end
  end
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__)) unless $LOAD_PATH.include?(File.expand_path('../lib', __dir__))
LIB_DIR = File.expand_path('../lib', __dir__) unless defined?(LIB_DIR)

require 'common/gui/account_manager'
require 'common/authentication/entry_store'
require 'common/authentication/authenticator'
require 'common/authentication/launch_data'
