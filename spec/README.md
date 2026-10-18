# Lich Test Suite

This directory contains RSpec tests and JavaScript renderer tests for this
lich-6 development tree. The [WebUI review record](../docs/webui-review-readiness.md)
separates implementation, acceptance evidence and outstanding platform checks.

The source-refresh acceptance spec covers pinned AbyssX and compass_and_wings setup
flows. Builder specs retain both historical and refreshed eloot source failures,
with explicitly repaired positive candidates; Bigshot's newer source has the same
Setup bytes. See the [fixture record](fixtures/webui/README.txt) for provenance,
external test boundaries and the compass startup-persistence distinction.

## Quick Start

```bash
# Run Ruby tests
rspec

# Run specific file
rspec spec/lib/dragonrealms/drinfomon/drstats_spec.rb

# Run with verbose output
rspec --format doc

# Run with specific seed (for reproducing failures)
rspec --seed 12345
```

## Parallel Runs and CI

```bash
# Whole suite across 4 workers (needs the parallel_tests gem)
parallel_rspec -n 4 spec
```

- Without bundler (global gems), set `PARALLEL_TESTS_EXECUTABLE=rspec` first.
- **CI failed?** The RSpec job log ends with a line like
  `TEST_ENV_NUMBER=2 PARALLEL_TEST_GROUPS=4 bundle exec rspec -O .rspec_parallel <files> --seed 1234`.
  Run that line to reproduce the failure exactly (drop `bundle exec` if you use
  global gems). It also rewrites `tmp/parallel_runtime_rspec.log`, which is harmless.
- **Every spec file must pass on its own** (`rspec path/to/file_spec.rb`).
  CI checks this for each spec file a PR changes.
- **Don't define shared globals in a spec.** Use `spec/support/`:
  `data_dir.rb` (DATA_DIR), `account_stub.rb` (Lich::Common::Account),
  `frontend_mock.rb` (::Frontend), `lich_sqlite.rb` (SQLite helpers).
- **Slow examples:** CI warns on any example over 2s in the spec files a PR
  changes (the full parallel run only flags examples over 60s). Speed it up, or
  tag it `:slow` if the time is unavoidable.

### Weak ownership checks

The WebUI adapter ownership specs cover abandoned graph collection alongside
retained detached widget reuse, callbacks, viewer drafts and focus reattachment.
Construct abandoned graphs on a short-lived worker and join it before requesting
GC on the example thread, returning only weak observation tokens. Initialize
memoized test dependencies before starting the worker; `Thread#value` propagates
worker failures. Returning from a helper on the collecting thread alone does not
eliminate conservative stack roots on every platform.

Keep pruning-boundary assertions independent of GC timing by supplying a
controlled dead reference, while retaining real collection/churn integration
checks and live callback checks. A metadata bound applies after earlier records
are actually collected; it is not a bound on live records awaiting collection.
Do not replace these checks with relaxed thresholds, sleeps or production GC.
When changing the harness, confirm that deliberate strong-retention and
disabled-pruning mutations still fail, and validate with parallel workers.

## WebUI JavaScript Tests

From the repository root, install the locked test dependencies and run every
`spec/webui/webui_*_test.cjs` suite:

```bash
npm ci --prefix spec/webui
npm test --prefix spec/webui
```

Use Node 22.22.2+, 24.15.0+, or 26+ as specified in
`spec/webui/package.json`. The lockfile pins the dependency tree; rerun `npm ci`
after it changes. Dependencies are local to the ignored `spec/webui/node_modules`
directory. No global installation or `NODE_PATH` is needed. Node and jsdom are
test tools, not requirements for running Lich or converted scripts.

The command runs both the lightweight renderer fixtures and the jsdom DOM tests,
and exits unsuccessfully if a dependency cannot load or an assertion fails.
RSpec does not invoke these suites. Browser layout requires actual browser
checks; GTK visual parity requires comparison with the original GTK interface;
OS-window geometry, restoration and cleanup require actual OS-window checks.
The JavaScript suites alone do not establish any of those behaviors.
The separate `WebUI Tests` GitHub Actions workflow runs these suites on Ubuntu 26.04.
It runs on pushes to `main` and manual dispatch, and on pull requests that change
WebUI-relevant paths (listed in the workflow); other pull requests skip it.
RSpec runs separately in its own workflow; the renderer job does not replace it.

## WebUI Browser Tests

Progress-provider lifecycle checks live in
`spec/lib/common/script_scope_style_spec.rb`, with the preserved spellson case in
`script_scope_widgets_spec.rb`. They cover source-derived staminabar2 declarations
(provenance recorded in the spec), positional loading, live reload/removal,
priority, authored-value restoration, owner isolation and cleanup. These are
isolated style/control checks, not whole-script or gameplay acceptance. PR 2's
first slice adds synthetic cases for unloaded/recognized/omitted states,
recognized-to-omitted resets, lower-priority recognized providers, re-recognition,
inert URL/import strings, bounded-input refusals and per-owner attributed notices.
`script_scope_decoration_spec.rb` adds synthetic checks for shared widget contexts,
class snapshots and bounds, screen-provider bookkeeping, owner/lifetime rejection,
cleanup and consolidated CSS versus geometry notices. `script_scope_css_corpus_spec.rb`
tests all 71 retained payloads and executes reviewed CSS-only excerpts from eleven
scripts. `fixtures/webui/css-decoration.json` records source hashes, lines, call
shapes, substitutions and measurements. See the [acceptance report](../docs/webui-css-decoration-acceptance.md)
for reproduction and per-script limitations; no whole game scripts run. The adapter specs verify
optional-property reset validation and stable rendered
identity; the compact renderer suite verifies that reset colors/heights disappear.
The independent `shim-progress-style` Chrome case in the existing widget suite
checks attach-before-load, callback-driven reload/omission/re-recognition/removal,
stable component identity, fraction preservation, unchanged sibling typography,
no request to the omitted CSS URL and final window closure. Its label context and
unmatched screen rules remain inert, and local class names do not appear in the DOM.
`script_scope_manatimer_spec.rb` checks progress text/fraction, overlay alignment,
pass-through lifetime, window decoration requests and unchanged source blocks.
Its `shim-manatimer` Chrome scenario checks centered text, fraction updates and
right-click routing through the layer; toggling pass-through off blocks the bar.
It runs in the existing Chrome CI job, including unchanged complete setup through
the Display chain with saved-position fixture data. `script_scope_geometry_cursor_spec.rb`
covers owner/teardown refusals and pinned gemstonev/highlight-manager excerpts;
its `shim-geometry-cursors` browser scenario checks inherited cursor modes/reset
and submitting-viewer monitor measurements. `monitor_geometry_spec.rb` checks
signed selection, explicit fallbacks, platform-provider parsing and viewer isolation.
Platform-provider fixtures do not certify native Windows/Linux behavior.
`scheduler_spec.rb` and `script_scope_scheduling_spec.rb` cover bounded scheduling,
owner/viewer attribution, repeat/stop results, cancellation races, backpressure,
teardown and retained host handles. `script_scope_scheduling_acceptance_spec.rb`
uses the pinned `scheduling.json` source blocks: repository's actual ten-second
timer and sail2's original startup race. Positive sail2 setup/save uses an explicit
test-only readiness sentinel; inherited sensitivity and the original hide/destroy
Close callback are positive acceptance cases. Four Chrome scenarios run in the
existing browser CI job, including a separate retained-input hide/timed-show case.
Native WebKit verifies the real owned window disappears and returns. Gemstonev
difficulty-window acceptance uses the unchanged source and captures its command
and main-window handoff; it does not certify the main game window.
No script download or settings-file write occurs; commands and saves are captured.
`browser_integration_spec.rb` adds `native-progress-sizing`: plain and colored
tracks at 18/24/36px, color removal without geometry changes, visible labels,
the 18px default and indeterminate/reduced-motion behavior. It uses the same
core renderer as shim controls and runs in the existing browser CI selection.

HeaderBar coverage in `script_scope_header_bar_spec.rb` verifies title replacement,
owner isolation, content identity, close vetoes and cleanup. With
`NATIVE_BROWSER=1`, it also checks header action/input behavior and the original
tpick welcome setup in Chrome. `fixtures/webui/tpick-titlebar.json` retains
unchanged source methods and hashes. Information/settings header construction
passes. `script_scope_tpick_setup_spec.rb` adds full default settings/information,
source data and callbacks, required cues, profile/default/save persistence and
explicit Monk/Paladin source-defect and optional-image boundaries. Grid rebasing,
label provider lifecycle, empty/live notebooks and renderer layout are separately
regressed. Native WKWebView validation is recorded in the handoff.

The progress browser fixture also loads original tpick global/label CSS from the retained corpus fixture
and verifies that its requested font does not replace the WebUI theme.

The same workflow has a separate Linux Chrome job. Playwright drives the existing
shim entry/checkbox and separator fixtures, plus a native-page callback fixture.
The model/tree/ComboBox case also checks expansion, text edits, toggles, multiple
selection and duplicate option labels against real Ruby callbacks. Each starts
with the production private `file:///` bootstrap and a fresh browser
cookie jar, asserting the `/auth` intermediate document, authenticated final page,
rendered controls and Ruby callback results. No game account or native GTK is used.
The Builder case loads the complete unchanged `ecleanse` setup XML and invokes
its original callbacks with isolated game lookups and a temporary settings path.
It checks keyboard behavior, disabled controls, mutually exclusive options,
Close saving and layout at requested/larger viewport sizes. Geometry assertions
detect overlapping checkbox labels, horizontal overflow and an inaccessible
footer. Separate Ruby lifecycle tests verify that detach and browser exit
destroy the setup without saving. Fixture provenance and limits are recorded in
[`fixtures/webui/README.txt`](fixtures/webui/README.txt).

The unchanged `ewaggle` Builder fixture adds table prefix search, cross-list
transfers, original same-list duplication, named choices, numeric edits and save
callbacks. It uses the same browser command below and runs in the existing CI job.
The repository fixture also covers character-by-character search, fixed headers,
the last column's keyboard resize handle and retained widths, and independent
scrolling of long comments without moving the list. Its inert listing has enough
rows to overflow the list viewport; original script construction and filtering
remain unchanged. DOM tests force an older search response between newer edits
and verify that superseded retries cannot replace the final query or prevent a
subsequent intentional script reset.
The original `ebounty`, `eherbs`, and `BlackArts` setups each have an independent
browser example in that job. A failure in one does not skip the others. Their
tests cover dependent checkbox resets, availability, editable combo choices,
list add/delete/reset, button sizing, and Close/save as applicable. The original
`ebounty` and `BlackArts` list callbacks require Lich's nil extension; their
examples invoke the same selected example in a separate Ruby process with that
actual extension loaded. Child failures or an empty/pending child run fail the
parent example. The parent suite's NilClass remains unchanged. The expected
`eloot` missing-ID refusal is checked in the same production environment.

Huntplan adds an independent Chrome case for its original hidden-tab setup,
character limit, invalid profile-slot message and Save & Exit callback. The
unchanged Bigshot fixture records its missing `boon_flee_from` tooltip lookup as
an expected source failure; zero unmapped XML declarations do not imply that
its setup callbacks were successfully connected. Unhandled queued Builder errors
must also close the owner's UI and request script termination. Separate corrected
eloot and Bigshot candidates apply exact, test-only source repairs after digest
checks; their original fixtures remain untouched. Each adds an independent Chrome
case covering controls, dependencies and Close/save. Ruby checks additionally
cover all eloot list handlers, tipping dispatch, Bigshot profile/boon migration,
scalar fields and text areas, and destruction without saving. The shared control
browser case verifies TextView focus-out independently of text changes.

Queued setup handlers may enqueue further handlers. A fixed number of queue
markers proves only that preceding work has run, not that nested work is finished.
For asynchronous acceptance, wait with a deadline for the required observable
state and check callback diagnostics, then assert the result. The Bigshot profile
load example checks its loaded fields and dependent fog control together. A
timeout remains a failure; sleeps alone, extra markers and reruns must not stand
in for completion. RSpec's random seed controls example ordering, not thread
scheduling.

Native external-link policy can be checked on macOS without opening a browser:

```bash
xcrun swiftc lib/webui/native/macos/ExternalLinks.swift spec/webui/native_link_policy.swift -o /tmp/lich-link-policy
/tmp/lich-link-policy
zsh lib/webui/native/macos/build.sh
```

The policy check verifies trusted main-frame link activation, HTTP(S) destinations,
and refusal of redirects, subframes, credential URLs and local cross-port links.

After `npm ci --prefix spec/webui`, install Chrome if it is not already available:

```bash
cd spec/webui
npx --no-install playwright install chrome
cd ../..
```

CI installs the browser system dependencies (reusing the runner image's Chrome)
and runs these files through Bundler, split across two shards with two parallel
workers each (see `.github/workflows/webui_tests.yaml`; a new browser spec file
must be added to one shard and to the command below). Run the same browser
selection locally from the repository root in the initialized Ruby shell:

```bash
NATIVE_BROWSER=1 rspec spec/lib/common/script_scope_source_refresh_spec.rb spec/lib/common/script_scope_scheduling_acceptance_spec.rb spec/lib/common/script_scope_geometry_cursor_spec.rb spec/lib/common/script_scope_manatimer_spec.rb spec/lib/common/script_scope_widgets_spec.rb spec/lib/common/script_scope_builder_spec.rb spec/lib/common/script_scope_builder_remaining_spec.rb spec/lib/webui/browser_integration_spec.rb spec/lib/common/script_scope_header_bar_spec.rb spec/lib/common/script_scope_tpick_setup_spec.rb --tag browser
```

Chrome runs headlessly in an isolated Playwright context. The browser runner has
bounded waits and closes its browser; RSpec stops the service and removes the
private bootstrap directory. Setup scenarios wait for server-confirmed page closure
before terminating Chrome. Failures propagate to RSpec and save screenshots under
ignored `spec/webui/test-results/`. Traces are retained for every browser run so
failures in subsequent Ruby saved-state assertions also have browser diagnostics;
CI uploads them on job failure and retains them for seven days. Only disposable
fixture state is used. Missing browser/dependencies
fail the explicit run rather than silently skipping it.

The original ewaggle Ruby regression also submits final combo/numeric values
directly through Close without preceding change events. It checks the original
settings-file callback, independently of browser timing. Related cases verify
that already accepted changes are not repeated and reconciliation is viewer-local.

Ordinary `rspec` leaves explicitly gated browser cases pending, so local Ruby testing does
not require Node or Chrome. Node, jsdom and Playwright are test-only dependencies.
These checks cover browser rendering and transport; they do not establish native
app-window focus, always-on-top, OS geometry or process-cleanup acceptance.
Windows/Linux platform acceptance beyond these checks and the macOS AppKit host
remain separate from this Linux-only workflow.

## Directory Structure

Spec files mirror the `lib/` directory structure:

```
spec/
├── spec_helper.rb           # Shared mocks, contexts, and configuration
├── fixtures/                # Test data files (effect-list.xml, etc.)
├── lib/
│   ├── common/              # Tests for lib/common/
│   ├── dragonrealms/
│   │   ├── commons/         # Tests for lib/dragonrealms/commons/
│   │   └── drinfomon/       # Tests for lib/dragonrealms/drinfomon/
│   └── gemstone/            # Tests for lib/gemstone/
└── *.rb                     # Legacy specs (being migrated)
```

## Spec Standards

### 1. Always Require spec_helper

Every spec file must start with:

```ruby
# frozen_string_literal: true

require_relative '../../../spec_helper'  # Adjust path based on depth
```

### 2. Use `described_class` Instead of Hardcoded Class Names

```ruby
# Good
RSpec.describe Lich::DragonRealms::DRStats do
  it 'does something' do
    expect(described_class.guild).to eq('Moon Mage')
  end
end

# Bad - hardcodes the class name
RSpec.describe Lich::DragonRealms::DRStats do
  it 'does something' do
    expect(Lich::DragonRealms::DRStats.guild).to eq('Moon Mage')
  end
end
```

### 3. Reset State via `class_variable_set` or Mock `reset!`

Production code must NOT contain test-only methods. Use `class_variable_set`
for production classes, or `reset!` on spec_helper mock modules:

```ruby
# For specs that load REAL production classes:
before(:each) do
  # NOTE: class_variable_set used because DRStats is a production class with no reset! method
  described_class.class_variable_set(:@@guild, nil)
  described_class.class_variable_set(:@@race, nil)
end

# For specs that use MOCK modules from spec_helper:
before(:each) do
  described_class.reset!  # reset! is defined on the mock, not production
end
```

Mock modules with `reset!` (defined in spec_helper.rb, NOT production):
- `DRC.reset!` - clears hand state
- `DRStats.reset!` - resets stats to defaults
- `DRSkill.reset!` - clears rank/xp hashes
- `DRSpells.reset!` - clears known spells, feats, parsing state
- `DRRoom.reset!` - clears npcs, pcs, group members
- `Flags.reset!` - clears all flags and matchers
- `UserVars.reset!` - clears all user variables

### 4. Use Shared Examples for Repetitive Patterns

When testing similar behavior across multiple cases, use shared examples:

```ruby
# Defined in spec_helper.rb
RSpec.shared_examples 'guild predicate' do |guild_name, method_name|
  describe ".#{method_name}" do
    it "returns true when guild is #{guild_name}" do
      described_class.guild = guild_name
      expect(described_class.send(method_name)).to be true
    end
    # ... more tests
  end
end

# Usage in spec file
describe 'guild predicate methods' do
  include_examples 'guild predicate', 'Barbarian', :barbarian?
  include_examples 'guild predicate', 'Bard', :bard?
  # ...
end
```

### 5. Use Shared Contexts for Common Setup

```ruby
# Defined in spec_helper.rb
RSpec.shared_context 'XMLData stubs' do
  before do
    allow(XMLData).to receive(:name).and_return('TestChar')
    allow(XMLData).to receive(:health).and_return(100)
    # ...
  end
end

# Usage in spec file
RSpec.describe MyClass do
  include_context 'XMLData stubs'
  # Tests can now use XMLData without additional setup
end
```

Available shared contexts:
- `'XMLData stubs'` - common character info (name, health, mana, etc.)
- `'DRSpells XMLData stubs'` - active spells, slivers, stellar percentage

### 6. Use `unless defined?` Guards for Mock Definitions

When defining mocks that might conflict with production code:

```ruby
module MyMock
  def self.some_method
    'mock value'
  end
end unless defined?(MyMock)
```

### 7. Define Mocks at Top Level, Alias into Namespace

To ensure `expect()` and namespaced code reference the same object:

```ruby
# Define at top level first
module DRC
  def self.bput(*args)
    'default'
  end
end unless defined?(DRC)

# Then alias into namespace
Lich::DragonRealms::DRC = DRC unless defined?(Lich::DragonRealms::DRC)
```

### 8. Use `allow()` Stubs, Not Custom Mock Methods

```ruby
# Good - uses RSpec stubs
allow(DRSkill).to receive(:getrank).with('Evasion').and_return(100)

# Bad - defines custom mock methods that may conflict
def DRSkill.getrank(skill)
  100
end
```

### 9. Match Real Type (Class vs Module)

Ruby raises `TypeError` if you define a class where production expects a module:

```ruby
# Production code
module DRStats; end

# Good - matches production type
module DRStats
  def self.guild; 'Moon Mage'; end
end

# Bad - type mismatch will cause errors
class DRStats  # TypeError!
  def self.guild; 'Moon Mage'; end
end
```

Known types:
- **Classes**: `DRSkill`, `DRRoom`, `Room`, `Script`, `Flags`
- **Modules**: `DRStats`, `DRC`, `DRCI`, `DRCA`, `DRCT`, `DRSpells`, `UserVars`

### 10. Reset State in `before(:each)` Hooks

Always reset shared state to ensure test isolation:

```ruby
RSpec.describe MyClass do
  before(:each) do
    described_class.reset!
    XMLData.reset
    Flags.reset!
  end
end
```

The global `config.before` hook in spec_helper.rb handles common resets, but spec-specific state should be reset in the spec file.

## Test Helpers

### Setting Skill Values

```ruby
DRSkill.set_xp('Evasion', 25)
DRSkill.set_rank('Evasion', 500)
```

### Pre-setting Flag Values

```ruby
# Set a flag value that survives Flags.add calls
Flags.set_pending('my_flag', ['matched value'])
```

## Running Tests

### All Tests
```bash
rspec
```

### Specific Directory
```bash
rspec spec/lib/dragonrealms/
```

### With Coverage
```bash
COVERAGE=true rspec
```

### Debug Mode (shows output)
```bash
DEBUG=1 rspec spec/path/to/spec.rb
```

## Common Issues

### Cross-Spec Pollution

**Symptom**: Tests pass individually but fail when run together.

**Cause**: Shared state not reset between tests.

**Fix**: Add `reset!` calls in `before(:each)` or use the global reset hook.

### Mock/Production Mismatch

**Symptom**: `expect(MyModule)` doesn't match calls to `Lich::DragonRealms::MyModule`.

**Cause**: Two different objects with the same name.

**Fix**: Ensure top-level mock is aliased into namespace:
```ruby
Lich::DragonRealms::MyModule = ::MyModule
```

### Undefined Method on Nil

**Symptom**: `NoMethodError: undefined method 'foo' for nil:NilClass`

**Cause**: Production code relies on NilClass `method_missing` monkey-patch.

**Fix**: For a unit test, isolate the specific dependency. For original-script
acceptance, do not fabricate nil behavior or silently repair the source. The
Builder harness uses a separate Ruby process with Lich's actual NilClass
extension where production behavior requires it, and keeps missing Builder IDs
as explicit failures. Document that dependency and any separately labeled source
repair; see [fixture provenance](fixtures/webui/README.txt).

### Missing Standard Library

**Symptom**: `NameError: uninitialized constant SomeModule::Date` (or `Time`, `JSON`, etc.)

**Cause**: Production code uses a standard library class that isn't loaded in test context.

**Fix**: Add the require to `spec_helper.rb`:
```ruby
require 'date'
require 'json'
require 'time'
```

## Test Design Principles

### DAMP vs DRY

Tests prioritize **DAMP** (Descriptive And Meaningful Phrases) over DRY (Don't Repeat Yourself).

**DAMP is preferred when:**
- Test intent should be immediately obvious
- Each test should be self-contained and readable
- Duplication makes the test easier to understand

```ruby
# Good - DAMP: clear what each test does
it 'returns nil for non-Moon Mage guilds' do
  described_class.guild = 'Barbarian'
  expect(described_class.native_mana).to be_nil
end

it 'returns lunar for Moon Mage guild' do
  described_class.guild = 'Moon Mage'
  expect(described_class.native_mana).to eq('lunar')
end
```

**DRY is preferred when:**
- Multiple tests share identical setup (use `shared_context`)
- Testing the same behavior with different inputs (use `shared_examples`)
- Repetitive assertions follow a clear pattern

```ruby
# Good - DRY: shared example for 12 identical guild predicate tests
RSpec.shared_examples 'guild predicate' do |guild_name, method_name|
  it "returns true when guild is #{guild_name}" do
    described_class.guild = guild_name
    expect(described_class.send(method_name)).to be true
  end
end

# Usage
include_examples 'guild predicate', 'Barbarian', :barbarian?
include_examples 'guild predicate', 'Moon Mage', :moon_mage?
```

### SOLID Principles in Tests

#### Dependency Inversion (DIP)

**Prefer existing production lifecycle APIs or test-double `reset!` methods:**

```ruby
# Good - uses public API
before(:each) do
  described_class.reset!
end

# Avoid - couples to internal implementation
before(:each) do
  described_class.class_variable_set(:@@some_var, [])
end
```

**When `class_variable_set` is acceptable:**
1. Testing the class variable implementation itself
2. No suitable production lifecycle method exists; do not add a production reset solely for tests
3. Document the reason with a comment

```ruby
# NOTE: class_variable_set acceptable here because we're testing
# the class variable refactoring from @ to @@. This tests the
# implementation detail by design.
```

#### Single Responsibility (SRP)

Each test should verify one behavior:

```ruby
# Good - single responsibility
it 'sets the guild' do
  described_class.guild = 'Moon Mage'
  expect(described_class.guild).to eq('Moon Mage')
end

# Bad - tests multiple unrelated things
it 'sets guild and race and age' do
  described_class.guild = 'Moon Mage'
  described_class.race = 'Elf'
  described_class.age = 30
  expect(described_class.guild).to eq('Moon Mage')
  expect(described_class.race).to eq('Elf')
  expect(described_class.age).to eq(30)
end
```

### Documenting Skipped Tests

When using `xit` or `skip`, always document:
1. **Why** it's skipped
2. **What fix** is needed
3. **Severity** of the test gap
4. **Tracking** reference (or TODO to create issue)

```ruby
# ISSUE: Production bug - GameObj.right_hand returns same instance.
# Fix: Add .dup call in the reader method.
# Severity: Low - scripts rarely mutate hand objects.
# Tracking: Create GitHub issue when addressing this.
xit 'returns duplicate hand objects' do
  # test code...
end
```

For environment-dependent skips:

```ruby
it 'requires full game environment' do
  skip 'Requires network connection and game client'
  # integration test code...
end
```

### Test Isolation Checklist

Before submitting a spec file, verify:

- [ ] `before(:each)` calls appropriate `reset!` methods
- [ ] Global variables (`$foo`) are reset if modified
- [ ] Class variables are reset via `reset!` or documented `class_variable_set`
- [ ] Tests pass with randomized ordering; investigate a failing seed rather than rerunning until green
- [ ] Tests pass in isolation: `rspec path/to/specific_spec.rb`
- [ ] Tests pass when run with full suite: `rspec`

### Production Code Requirements for Testability

Use production ownership and disposal boundaries, immutable constants, and
dependency injection where practical. A real reset/close operation may be tested
through its public API, but do not add test-only production methods. Test doubles
may expose `reset!`; tests of legacy shared state may restore that state directly
with a comment explaining the isolation requirement, as described above.
