# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../login_spec_helper'
require 'common/webui_launcher'
require 'timeout'

# Fixture types stay local to this workflow-focused example group.
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe Lich::Common::WebUILauncher, 'actual-core workflows' do
  Event = Data.define(:viewer_id, :payload, :submission)

  class ImmediateExecutor
    # Executes synchronously while honoring the production cleanup ownership contract.
    # @param cleanup [Proc, nil] completion cleanup
    # @yield fixture work
    # @return [Boolean] true after accepting the work
    def post(cleanup: nil, &work)
      work.call
      true
    ensure
      cleanup&.call
    end

    def stop(wait: true) = wait
  end

  class WorkflowFrontendLocator
    Resolution = Data.define(:frontend_id) do
      def executable_path = '/fixture/frontend'
      def source = :detected
    end

    class << self
      attr_accessor :resolved
    end
    self.resolved = []

    def self.available(gui_selectable:, refresh:)
      raise unless gui_selectable && refresh

      [Resolution.new('stormfront')]
    end

    def self.resolve(frontend, refresh: false)
      self.resolved << [frontend, refresh]
      Resolution.new(frontend) if frontend == 'stormfront'
    end
  end

  class WorkflowService
    attr_reader :terminated, :stopped, :refreshes

    def initialize
      @refreshes = 0
    end

    def refresh(_page) = @refreshes += 1
    def terminate_owner(owner) = @terminated = owner
    def stop = @stopped = true
  end

  class WorkflowCatalog
    attr_accessor :entries_value, :mode, :keychain, :require_master, :master_valid
    attr_reader :calls

    def initialize(entry)
      @entries_value = [entry]
      @mode = :standard
      @keychain = true
      @require_master = false
      @master_valid = true
      @calls = []
    end

    def entries(autosort: false) = autosort ? @entries_value.sort_by(&:char_name) : @entries_value
    def accounts = @entries_value.map(&:user_id).uniq
    def encryption_mode = @mode
    def enhanced_encryption_available? = @keychain

    def credential(key, master_password: nil)
      @calls << [:credential, key, master_password]
      raise Lich::Common::WebUILauncher::Catalog::MasterPasswordRequired if @require_master && master_password.nil?

      Lich::WebUI::SensitiveValue.server('origin-b-saved-canary')
    end

    def validate_master_password(password)
      @calls << [:validate_master, password.dup]
      @master_valid
    end

    def upsert_manual_entry(entry, password)
      @calls << [:save_manual, entry, password]
      true
    end

    def toggle_favorite(key) = @calls << [:favorite, key]
    def remove_entry(key) = @calls << [:remove_entry, key]
    def remove_account(account) = @calls << [:remove_account, account]
    def add_character(account, character) = @calls << [:add_character, account, character]
    def update_character(key, character) = @calls << [:update_character, key, character]
    def update_launcher_setting(setting, value) = @calls << [:setting, setting, value]

    def add_or_update_account(account, password, characters, frontend:)
      @calls << [:save_account, account, password, characters, frontend]
      true
    end

    def change_encryption_mode(mode, master_password: nil)
      @calls << [:change_encryption, mode, master_password]
      @mode = mode
      true
    end

    def change_master_password(current, replacement)
      @calls << [:change_master, current, replacement]
      true
    end
  end

  let(:entry) do
    Lich::Common::WebUILauncher::Catalog::Entry.new(
      'entry-0', 'DOUG', 'Aldor', 'GS3', 'GemStone IV', 'stormfront', nil, nil, false, nil
    )
  end
  let(:catalog) { WorkflowCatalog.new(entry) }
  let(:service) { WorkflowService.new }
  let(:launches) { [] }
  let(:messages) { [] }
  let(:executor) { ImmediateExecutor.new }
  let(:authenticator) do
    Class.new do
      class << self
        attr_accessor :calls
      end
      self.calls = []

      def self.authenticate(**arguments)
        calls << arguments.transform_values { |value| value.is_a?(String) ? value.dup : value }
        if arguments[:legacy]
          [{ char_name: 'Aldor', game_code: 'GS3', game_name: 'GemStone IV' }]
        else
          { game: 'STORM', key: 'session-key', gamehost: 'example', gameport: '1' }
        end
      end
    end
  end
  let(:launcher) do
    described_class.new(
      data_dir: '/fixture', catalog: catalog, service: service, authenticator: authenticator,
      executor: executor, on_launch: ->(launch, origin) { launches << [origin, launch] },
      browser_open: proc { true }, frontend_locator: WorkflowFrontendLocator,
      logger: ->(level, message) { messages << [level, message] }
    )
  end

  def event(values = {}, viewer: 'viewer-1', payload: {})
    Event.new(viewer, payload, Lich::WebUI::Submission.new(viewer_id: viewer, values: values))
  end

  def viewer_secret(value)
    Lich::WebUI::SensitiveValue.viewer(value)
  end

  it 'refuses preference writes after launcher closure' do
    launcher.close
    launcher.setting_changed(event({}, payload: { value: true }), :dark_theme)

    expect(catalog.calls).to be_empty
    expect(launcher.send(:render_state)[:dark_theme]).to be(false)
  end

  context 'cancellation with the real launcher worker' do
    let(:executor) { described_class::SerialExecutor.new }
    let(:started) { Queue.new }
    let(:release) { Queue.new }
    let(:carriers) { [] }

    before do
      allow(Lich::WebUI::SensitiveValue).to receive(:viewer).and_wrap_original do |original, value|
        original.call(value).tap { |carrier| carriers << carrier }
      end
    end

    after do
      release << true
      launcher.close
      executor.stop
    end

    it 'cancels a queued master-password write and clears its transferred carriers' do
      executor.post { started << true; release.pop }
      Timeout.timeout(2) { started.pop }
      launcher.change_master_password(event({
        'password_input:master-current' => viewer_secret('synthetic-current'),
        'password_input:master-new'     => viewer_secret('synthetic-replacement'),
        'password_input:master-confirm' => viewer_secret('synthetic-replacement'),
      }))
      launcher.close

      expect(carriers.size).to eq(6)
      expect(carriers).to all(be_consumed)
      release << true
      executor.stop
      expect(catalog.calls).to be_empty
    end

    it 'refuses an account write after authentication returns to an already closed launcher' do
      allow(authenticator).to receive(:authenticate) do
        started << true
        release.pop
        [{ char_name: 'Aldor', game_code: 'GS3' }]
      end
      launcher.save_account(event({ 'text_input:account-name' => 'DOUG', 'select:account-frontend' => 'stormfront',
                                   'password_input:account-password' => viewer_secret('synthetic-account') }))
      Timeout.timeout(2) { started.pop }
      launcher.close
      release << true
      executor.stop

      expect(catalog.calls).to be_empty
      expect(carriers).to all(be_consumed)
    end

    it 'disposes credentials produced by manual authentication that completes after close' do
      allow(authenticator).to receive(:authenticate) do
        started << true
        release.pop
        [{ char_name: 'Aldor', game_code: 'GS3' }]
      end
      launcher.manual_connect(event({ 'account' => 'DOUG', 'password' => viewer_secret('synthetic-account') }),
                              'account', 'password')
      Timeout.timeout(2) { started.pop }
      launcher.close
      release << true
      executor.stop

      expect(carriers.size).to eq(3)
      expect(carriers).to all(be_consumed)
      expect(launches).to be_empty
    end

    it 'does not launch a saved session after close wins during authentication' do
      allow(authenticator).to receive(:authenticate) do
        started << true
        release.pop
        { game: 'STORM', key: 'synthetic-key', gamehost: 'example', gameport: '1' }
      end
      launcher.saved_launch(event, 'entry-0')
      Timeout.timeout(2) { started.pop }
      launcher.close
      release << true
      executor.stop

      expect(launches).to be_empty
    end

    it 'lets an admitted write finish before close completes' do
      writes = []
      allow(catalog).to receive(:change_master_password) do
        started << true
        release.pop
        writes << :saved
        true
      end
      launcher.change_master_password(event({
        'password_input:master-current' => viewer_secret('synthetic-current'),
        'password_input:master-new'     => viewer_secret('synthetic-replacement'),
        'password_input:master-confirm' => viewer_secret('synthetic-replacement'),
      }))
      Timeout.timeout(2) { started.pop }
      closer = Thread.new { launcher.close; writes << :closed }
      Timeout.timeout(2) { Thread.pass until closer.status == 'sleep' || !closer.alive? }
      expect(writes).to be_empty
      release << true
      Timeout.timeout(2) { closer.join }
      executor.stop
      expect(writes).to eq(%i[saved closed])
    ensure
      release << true
      closer&.join
    end
  end

  it 'launches a saved entry with an Origin B credential that never enters the render tree' do
    launcher.saved_launch(event, 'entry-0')

    expect(authenticator.calls.last[:password]).to eq('origin-b-saved-canary')
    expect(launches.last.first).to eq(:saved_entry)
    tree_text = launcher.send(:build_page).render.tree.to_h.to_s
    expect(tree_text).not_to include('origin-b-saved-canary')
  end

  it 'supports master-password unlock failure, retry, success, and cancel' do
    catalog.require_master = true
    launcher.saved_launch(event, 'entry-0')
    expect(launcher.send(:render_state)[:modal]).to include(kind: :unlock)

    catalog.master_valid = false
    launcher.unlock_response(event({ 'password' => viewer_secret('wrong') }, payload: { button: 'unlock' }), 'password')
    expect(launcher.send(:render_state)[:modal][:error]).to match(/not accepted/)

    catalog.master_valid = true
    launcher.unlock_response(event({ 'password' => viewer_secret('correct') }, payload: { button: 'unlock' }), 'password')
    expect(launches.last.first).to eq(:saved_entry)

    alternate = described_class.new(
      data_dir: '/fixture', catalog: catalog, service: WorkflowService.new, executor: ImmediateExecutor.new,
      on_launch: proc {}, browser_open: proc { true }
    )
    alternate.instance_variable_set(:@modal, { kind: :unlock, entry_key: 'entry-0' })
    alternate.unlock_response(event({}, payload: { button: 'cancel' }), 'password')
    expect(alternate.send(:render_state)[:modal]).to be_nil
  end

  it 'runs manual authentication, selection, save, favorite, and launch through core collaborators' do
    connect = event({ 'account' => 'doug', 'password' => viewer_secret('manual-canary') })
    launcher.manual_connect(connect, 'account', 'password')
    launcher.manual_play(event({ 'select:manual-frontend' => 'stormfront' }))
    expect(launches).to be_empty
    expect(launcher.send(:render_state)[:manual][:error]).to match(/select a character/)

    launcher.manual_select(event({}, payload: { rows: ['character-0'] }))
    launch = event({
      'select:manual-frontend' => 'stormfront', 'checkbox:manual-custom-enabled' => false,
      'text_input:manual-custom' => '', 'text_input:manual-custom-dir' => '',
      'checkbox:manual-save' => true, 'checkbox:manual-favorite' => true,
    })
    launcher.manual_play(launch)

    expect(catalog.calls.map(&:first)).to include(:save_manual, :favorite)
    expect(launches.last.first).to eq(:manual)
    expect(authenticator.calls.map { |call| call[:password] }).to include('manual-canary')
    expect(WorkflowFrontendLocator.resolved).to include(['stormfront', true])
  end

  it 'discards an unlock submission if its modal has already closed' do
    secret = viewer_secret('late-secret')

    expect(launcher.unlock_response(
             event({ 'password' => secret }, payload: { button: 'unlock' }), 'password'
           )).to be_nil
    expect(secret).to be_consumed
    expect(catalog.calls).to be_empty
  end

  [Lich::Common::WebUILauncher::Catalog::MasterPasswordRequired,
   Lich::Common::WebUILauncher::Catalog::LegacyConversionRequired, IOError, false].each do |failure|
    it "still launches after optional manual persistence fails with #{failure}" do
      if failure
        allow(catalog).to receive(:upsert_manual_entry).and_raise(failure, 'synthetic-secret-must-not-be-logged')
      else
        allow(catalog).to receive(:upsert_manual_entry).and_return(false)
      end
      launcher.manual_connect(event({ 'account' => 'doug', 'password' => viewer_secret('manual-canary') }),
                              'account', 'password')
      launcher.manual_select(event({}, payload: { rows: ['character-0'] }))
      launcher.manual_play(event({ 'select:manual-frontend' => 'stormfront', 'checkbox:manual-save' => true }))

      expect(launches.size).to eq(1)
      expect(launches.first.first).to eq(:manual)
      expect(messages).to include([:warning, a_string_matching(/not saved/)])
      expect(messages.to_s).not_to include('synthetic-secret-must-not-be-logged', 'manual-canary')
      expect(messages.to_s).to include('--convert-entries') if failure == described_class::Catalog::LegacyConversionRequired
    end
  end

  it 'still launches and reports a failed optional favorite write' do
    allow(catalog).to receive(:toggle_favorite).and_return(nil)
    launcher.manual_connect(event({ 'account' => 'doug', 'password' => viewer_secret('manual-canary') }),
                            'account', 'password')
    launcher.manual_select(event({}, payload: { rows: ['character-0'] }))
    launcher.manual_play(event({ 'select:manual-frontend' => 'stormfront', 'checkbox:manual-favorite' => true }))

    expect(launches.size).to eq(1)
    expect(messages).to include([:warning, a_string_matching(/not saved/)])
  end

  it 'gives actionable conversion guidance when an account save encounters legacy entries' do
    allow(catalog).to receive(:add_or_update_account).and_raise(described_class::Catalog::LegacyConversionRequired)
    launcher.save_account(event({ 'text_input:account-name' => 'DOUG', 'select:account-frontend' => 'stormfront',
                                 'password_input:account-password' => viewer_secret('synthetic-password') }))

    expect(launcher.send(:render_state)[:notice][:text]).to include('--convert-entries')
  end

  context 'manual favorites with the persisted catalog' do
    let(:data_dir) { Dir.mktmpdir('webui-manual-favorites') }
    let(:catalog) do
      described_class::Catalog.new(data_dir: data_dir,
                                   master_password_manager: double(keychain_available?: false))
    end

    before do
      catalog.upsert_manual_entry(entry.to_h, 'synthetic-password')
      catalog.upsert_manual_entry(entry.to_h.merge(custom_launch: '/fixture/custom'), 'synthetic-password')
      catalog.toggle_favorite(catalog.entries.first.key)
    end

    after { FileUtils.remove_entry(data_dir) }

    def play_manual_favorite(custom: nil)
      launcher.manual_connect(event({ 'account' => 'doug', 'password' => viewer_secret('manual-canary') }),
                              'account', 'password')
      launcher.manual_select(event({}, payload: { rows: ['character-0'] }))
      launcher.manual_play(event({
        'select:manual-frontend' => 'stormfront', 'checkbox:manual-custom-enabled' => !custom.nil?,
        'text_input:manual-custom' => custom, 'text_input:manual-custom-dir' => '',
        'checkbox:manual-save' => true, 'checkbox:manual-favorite' => true,
      }))
    end

    it 'keeps an existing favorite and its ordering when played again' do
      before = catalog.entries.first

      play_manual_favorite

      expect(launches.last.first).to eq(:manual)
      expect(catalog.entries.first.favorite).to be(true)
      expect(catalog.entries.first.favorite_order).to eq(before.favorite_order)
      expect(catalog.entries.last.favorite).to be(false)
    end

    it 'marks only the matching custom-launch variant as a favorite' do
      play_manual_favorite(custom: '/fixture/custom')

      expect(launches.last.first).to eq(:manual)
      expect(catalog.entries.map(&:favorite)).to eq([true, true])
      expect(catalog.entries.map(&:custom_launch)).to eq([nil, '/fixture/custom'])
    end
  end

  it 'refuses manual Play unless credentials, character, and an available frontend are selected' do
    rendered = launcher.send(:build_page).render.tree
    play = rendered.each.find { |component| component.cid.end_with?('button:manual-play') }
    expect(play.props[:disabled]).to be(true)

    launcher.manual_connect(event({ 'account' => 'doug', 'password' => viewer_secret('manual-canary') }),
                            'account', 'password')
    launcher.manual_select(event({}, payload: { rows: ['character-0'] }))
    ready = launcher.send(:build_page).render.tree.each.find { |component| component.cid.end_with?('button:manual-play') }
    expect(ready.props[:disabled]).to be(false)
    expect(launcher.send(:build_page).render.facilities[:accelerators])
      .to contain_exactly(hash_including(keys: 'enter', target: ready.cid, event: 'activate'))

    allow(WorkflowFrontendLocator).to receive(:resolve).and_return(nil)
    launcher.manual_play(event({ 'select:manual-frontend' => 'stormfront' }))
    expect(launcher.send(:render_state)[:manual][:error]).to match(/available front end/)
    expect(launches).to be_empty
  end

  it 'handles add and edit character persistence through the real catalog boundary' do
    values = {
      'select:character-account' => 'DOUG', 'text_input:character-name' => 'Cera',
      'select:character-game' => 'DR', 'select:character-frontend' => 'stormfront',
      'text_input:character-custom' => '', 'text_input:character-custom-dir' => '',
    }
    launcher.save_character(event(values))
    expect(catalog.calls.last.first).to eq(:add_character)

    launcher.instance_variable_set(:@draft_entry_key, 'entry-0')
    launcher.save_character(event(values.merge('text_input:character-name' => 'Aldor Prime')))
    expect(catalog.calls.last.first).to eq(:update_character)
  end

  it 'covers plaintext, standard, enhanced, keychain-unavailable, and master-password change paths' do
    %w[plaintext standard enhanced].each do |mode|
      launcher.change_encryption(event({
        'radio:encryption-mode'            => mode,
        'password_input:encryption-master' => viewer_secret(mode == 'enhanced' ? 'master-pass' : ''),
      }))
    end
    expect(catalog.calls.select { |call| call.first == :change_encryption }.map { |call| call[1] })
      .to eq(%i[plaintext standard enhanced])

    launcher.change_master_password(event({
      'password_input:master-current' => viewer_secret('current-pass'),
      'password_input:master-new'     => viewer_secret('replacement-pass'),
      'password_input:master-confirm' => viewer_secret('replacement-pass'),
    }))
    expect(catalog.calls.map(&:first)).to include(:change_master)

    catalog.keychain = false
    launcher.change_encryption(event({
      'radio:encryption-mode'            => 'enhanced',
      'password_input:encryption-master' => viewer_secret('blocked-pass'),
    }))
    expect(launcher.send(:render_state)[:notice][:text]).to match(/unavailable/)
  end

  %w[plaintext standard].each do |mode|
    ['', 'wrong', 'valid-master'].each do |password|
      it "requires the current master password before changing enhanced encryption to #{mode} with #{password.inspect}" do
        catalog.mode = :enhanced
        catalog.master_valid = password == 'valid-master'
        secret = viewer_secret(password)
        launcher.change_encryption(event({ 'radio:encryption-mode' => mode, 'password_input:encryption-master' => secret }))

        changes = catalog.calls.select { |call| call.first == :change_encryption }
        if catalog.master_valid
          expect(catalog.calls).to include([:validate_master, password])
          expect(changes).to eq([[:change_encryption, mode.to_sym, nil]])
        else
          expect(changes).to be_empty
          expect(launcher.send(:render_state)[:notice][:text]).to match(/failed/)
        end
        expect(secret).to be_consumed
      end
    end
  end

  it 'keeps saved multi-launch open but closes manual and single saved launches' do
    persistent_service = WorkflowService.new
    session_launcher = class_double(Lich::Common::SessionLauncher, launch: { ok: true })
    persistent = described_class.new(
      data_dir: '/fixture', catalog: catalog, service: persistent_service, authenticator: authenticator,
      executor: ImmediateExecutor.new, session_launcher: session_launcher, persistent: true,
      on_launch: proc {}, browser_open: proc { true }
    )
    persistent.saved_launch(event, 'entry-0')
    persistent.saved_launch(event, 'entry-0')

    expect(persistent.lifecycle).not_to eq(:closed)
    expect(persistent.active_operations).to be_empty
    expect(session_launcher).to have_received(:launch).with(
      kind_of(Array), launch_context: hash_including(data_dir: '/fixture', force_path_flags: true)
    ).twice
  end

  it 'switches tab/list layout and exercises saved versus automatic sort order under GUI Settings' do
    second = entry.with(key: 'entry-1', char_name: 'Bera')
    first = entry.with(key: 'entry-0', char_name: 'Aldor')
    catalog.entries_value = [second, first]

    launcher.setting_changed(event({}, payload: { value: true }), :settings_visible)
    launcher.setting_changed(event({}, payload: { value: false }), :tab_layout)
    list_tree = launcher.send(:build_page).render.tree
    expect(list_tree.each.map(&:cid)).to include(a_string_ending_with('stack:saved-list-layout'))
    expect(list_tree.each.map(&:cid)).not_to include(a_string_ending_with('tabs:saved-account-tabs'))

    launcher.setting_changed(event({}, payload: { value: true }), :tab_layout)
    launcher.setting_changed(event({}, payload: { value: true }), :autosort)
    sorted_tree = launcher.send(:build_page).render.tree
    doug_panel = sorted_tree.each.find { |component| component.cid.end_with?('stack:saved-account-DOUG') }
    expect(doug_panel.each.select { |component| component.type == :group }.map { |group| group.props[:label] })
      .to eq(['Aldor (GS Prime)', 'Bera (GS Prime)'])
    expect(catalog.calls).to include([:setting, :tab_layout, false], [:setting, :tab_layout, true],
                                     [:setting, :autosort, true])
  end

  it 'clears viewer-owned state and closes the launcher service when its browser window disconnects' do
    launcher.manual_connect(event({ 'account' => 'DOUG', 'password' => viewer_secret('disconnect-canary') }), 'account', 'password')
    launcher.browser_window_closed('viewer-1')

    expect(launcher.send(:render_state)[:manual][:phase]).to eq(:editing)
    expect(launcher.active_operations).to be_empty
    expect(launcher.lifecycle).to eq(:closed)
    expect(service.stopped).to be(true)
    expect(launcher.close(reason: :shutdown)).to be(false)
  end

  it 'admits only one shutdown path when window and process close signals race' do
    launcher.instance_variable_set(:@lifecycle, :closing)

    expect(launcher.close(reason: :browser_process_exit)).to be(false)
    expect(service.stopped).to be_nil
  end

  it 'terminates only its exactly owned browser process during launcher shutdown' do
    terminated = []
    launcher.instance_variable_set(:@browser_pid, 1234)
    launcher.instance_variable_set(:@browser_terminate, ->(signal, pid) { terminated << [signal, pid] })

    expect(launcher.close(reason: :launch)).to be(true)
    expect(terminated).to eq([['TERM', 1234]])
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock
