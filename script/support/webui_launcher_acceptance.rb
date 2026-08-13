# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'tmpdir'
require_relative '../../lib/version'

module Lich
  def self.log(message) = warn(message)

  module Util
    def self.install_gem_requirements(*)
      require 'os'
      require 'ffi'
      true
    end
  end
end

require 'common/webui_launcher'

acceptance_port = Integer(ENV.fetch('WEBUI_ACCEPTANCE_PORT', '0'), 10)
acceptance_data_dir = ENV.fetch('WEBUI_ACCEPTANCE_DATA_DIR', Dir.tmpdir)

class AcceptanceCatalog
  Entry = Lich::Common::WebUILauncher::Catalog::Entry

  def initialize
    @entries = [
      Entry.new('entry-0', 'DOUG', 'Bera', 'DR', 'DragonRealms', 'wizard', nil, nil, false, nil),
      Entry.new('entry-1', 'DOUG', 'Aldor', 'GS3', 'GemStone IV', 'stormfront', nil, nil, true, 1),
      Entry.new('entry-2', 'TEST', '<img src=x onerror=alert(1)>', 'GSF', 'GemStone IV Shattered',
                'stormfront', nil, nil, false, nil),
    ]
  end

  def entries(autosort: false)
    return @entries unless autosort

    @entries.sort_by { |entry| [entry.favorite ? 0 : 1, entry.game_name, entry.user_id, entry.char_name] }
  end

  def accounts = @entries.map(&:user_id).uniq
  def encryption_mode = :standard
  def enhanced_encryption_available? = true
  def legacy_conversion_needed? = false
  def toggle_favorite(*) = true
  def remove_entry(*) = true
  def remove_account(*) = true
  def add_character(*) = true
  def update_character(*) = true
end

launcher = Lich::Common::WebUILauncher.new(
  data_dir: acceptance_data_dir,
  service: Lich::WebUI::Service.new(port: acceptance_port),
  catalog: AcceptanceCatalog.new,
  on_launch: ->(_launch, origin) { warn("acceptance launch completed: #{origin}") },
  browser_open: ->(url) { puts(url); $stdout.flush; true },
  recovery: ->(message) { warn(message) }
)

launcher.start.await_launch
