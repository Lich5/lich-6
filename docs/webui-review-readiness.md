# WebUI review readiness and handoff

Current baseline: 2026-10-14, PR 4 branch `feat/webui-owner-glib-scheduling`,
started from synchronized `main` / `origin/main` at `5f2d0e86`
(PRs #41, #42, #43, #48, documentation PR #50 and geometry/cursor PR #54 merged).
The prior merge-status edits to this handoff and the fallback brief were preserved;
PR 4 is open as PR #55 at reviewed head `3f3f699e`; review follow-ups remain
unstaged. This record describes
the development tree, not an EO release. The original documentation reconciliation
was reviewed on 2026-10-11 against PR #38 at
`d3e41e71eb335acb80cdd599a3038026d5df5134`; its validation remains dated history.

## Reading the evidence

- [Architecture and integration](webui-integration.md) explains current contracts,
  ownership, accepted mappings, omissions and refusals.
- [Test guidance](../spec/README.md) gives Ruby, renderer, Chrome and native-host
  commands and explains what each kind of test establishes.
- [Fixture provenance](../spec/fixtures/webui/README.txt) identifies the retained
  original sources and exact, test-only source repairs.
- This record distinguishes merged implementation, remaining acceptance and
  proposed EO extraction. A mapped XML declaration is not proof that a script
  initializes, wires callbacks, saves correctly, or works in a live game.

The older numbered priority/slice plan and complete 15-script corpus audit are
not present as repository documents at this baseline. This record does not
invent their missing rows or renumber them. Corpus-wide property totals and
movement need the retained original audit imported with its source revision,
definitions and exclusions before being published here. The ten fixtures below
are a reproducible acceptance set, not a substitute denominator.

## Decisions that govern further work

Core WebUI owns contracts, validation, transport, viewer state, callback
dispatch, authentication and window lifecycle. Native consumers use it directly.
The script-local GTK shim translates a bounded surface through the bounded
[adapter](../lib/webui/adapter.rb); it does not own another service or event loop.
GTK support is a migration bridge. Unsupported meaningful behavior is refused;
a deliberately ignored presentation hint must have an explicit documented
disposition and diagnostic. No missing widget, script-specific layout, business
rule, settings persistence, or nil suppression is fabricated by the shim.

Original GTK appearance is the comparison target unless a documented boundary
requires a different result. Converted scripts are evidence for reusable native
behavior, not templates to copy into generic shim/core code. EO proposals and
unmerged implementations are references to evaluate, not authority to change
this design. Their current merge status is not asserted by this local audit.

Shared-core expansion requires a concrete need and an explicit decision; CSS
being used by the browser does not make arbitrary GTK CSS compatible. Builder
does not bypass the same controls' direct-call rules. Unknown XML IDs fail even
when production NilClass behavior would otherwise hide the error.

Each implementation branch starts from synchronized `main`. Dependent work waits
for its predecessor to merge, then starts from the new `main`; no stacked branch
train is assumed. Staging, commits and pushes remain human-only. RAR is review,
analysis and recommendation without edits until adopted.

## Merged implementation

These are development-history bundles, not a proposed one-for-one EO PR train.

| Work | Status | Development provenance |
| --- | --- | --- |
| Legacy box/layout extensions | Merged | PR #30, `0cd7df24` |
| Control conventions, radio/toggle/scalar behavior | Merged | PR #31, `60eca881` |
| Text, images, menus and related shared behavior | Merged | PR #32, `7f7a85fc` |
| Models, TreeView and ComboBox | Merged | PR #33, `9ea27087` |
| Builder foundation and ecleanse presentation | Merged | PR #34, `5d4d915a` |
| Builder interactions and ewaggle drag/drop | Merged | PR #35, `47f7e1c0` |
| ebounty/eherbs/BlackArts families and eloot refusal | Merged | PR #36, `fac0d525` |
| repository/go2 families and shared renderer repairs | Merged | PR #37, `57d31829` |
| Bigshot/Huntplan families, corrected-source acceptance and final review repairs | Merged | PR #38, `d3e41e71` |
| Progress provider lifecycle, optional-property reset and synchronized destruction | Merged | PR #41, `de876519` |
| CSS decoration fallback, widget contexts, class/screen providers and corpus acceptance | Merged | PR #42, `bea51ac3` |
| HeaderBar/titlebar, signed Grid origins/rollback, required label cues and default tpick setup | Merged | PR #43, `cd10f7b2` |
| Generic progress rendering, progress text/pointer events, overlay pass-through and decoration requests | Merged | PR #48, `d7726455` |

PR #38 includes the bounded wait for Bigshot's nested profile callbacks and the
refusal of both character-limit setters on internal combo entries. Neither is
outstanding. The latter preserves existing text and emits no change signal;
standalone Entry limits remain supported.

The current development baseline uses host/browser contract 2.19.0.

## Builder setup acceptance

Status applies to frozen setup excerpts and the harness conditions documented in
the fixture record. Tests exist in
[`script_scope_builder_spec.rb`](../spec/lib/common/script_scope_builder_spec.rb)
and [`script_scope_builder_remaining_spec.rb`](../spec/lib/common/script_scope_builder_remaining_spec.rb),
with browser actions in [`browser.spec.cjs`](../spec/webui/browser.spec.cjs).

| Script | Retained original | Explicitly repaired candidate / qualification |
| --- | --- | --- |
| ecleanse | Positive setup acceptance | Original initialization, controls, layout checks and save/destroy |
| ewaggle | Positive setup acceptance | Original list transfers, choices, scalar edits and save/destroy |
| ebounty | Positive setup acceptance | List callbacks need the existing production NilClass extension; isolated subprocess coverage |
| eherbs | Positive setup acceptance | Original availability, settings and close behavior |
| BlackArts | Positive setup acceptance | List callbacks need the existing production NilClass extension; isolated subprocess coverage |
| eloot | Expected hard stop: missing `exclusions_label` | Candidate names the existing XML label; original callbacks then receive Ruby/Chrome acceptance coverage |
| repository | Positive setup acceptance | Synthetic listings; download command captured without network execution |
| go2 | Positive setup acceptance | GS and DR layouts; travel/persistence destinations isolated |
| bigshot | Expected hard stop: missing `boon_flee_from` | Candidate removes obsolete tooltip lookup and repairs legacy boon migration; profile/control/save callbacks covered |
| huntplan | Positive setup acceptance | Original input limit, invalid-slot response and Save & Exit |
| **Total: 10 fixtures** | **8 positive originals; 2 expected source failures** | **2 separately repaired positive candidates; no production source repair in the shim** |

All of these fixtures have mapped XML declarations. That does not erase eloot's
or Bigshot's original-source failure, nor certify full gameplay, every profile,
pixel parity, or every OS host. An author-updated script needs a new provenance
check and acceptance run; the test-only repair must not be silently treated as
the released script.

## Open work and exclusions

### CSS decoration work tracker

Owner-approved sequence, 2026-10-12. Each PR starts from synchronized `main`
after the owner confirms its predecessor has merged. Statuses are **Not started**,
**In progress**, **Ready for owner review**, **Awaiting merge**, and **Merged**.
Local validation does not establish merge status. Staging, commits and pushes
remain human-only. When asked "what's left and what's next", report this table
with current evidence and the next concrete slice.

| Proposed PR | Included features / methods / widgets | Status |
| --- | --- | --- |
| 1. Progress provider lifecycle and compatibility | `CssProvider#load` and positional `load_from_data`; optional final semicolon in the bounded progress grammar; `ProgressBar` provider references, attach-before-load, reload and removal; APPLICATION/USER priorities and attachment-order ties; restoration of authored/default fill and height; owner synchronization, isolation and cleanup. Focused spellson/staminabar2 and lifecycle regressions. Explicitly approved adapter `UNSET` reset for optional shared properties. | **Merged**: [PR #41](https://github.com/Lich5/lich-6/pull/41), confirmed through GitHub on 2026-10-12, merged at `2026-10-12T07:35:31Z` as `de8765199cdea6e73ed19cd5a9b6fcab759abea6`. Includes the destruction-race review fix from head `6943dda12c24b24b53cf2ddb2e4dc14038690837`. |
| 2. Explicit CSS decoration fallback and acceptance | Unloaded/recognized/omitted providers; shared `Widget#style_context`; widget and owner-scoped screen provider attachment/removal; class add/remove/query; observed call forms; consolidated attributed omission notices; Screen geometry notice correction; CSS size measurements and cached-corpus acceptance accounting. Preserve unsupported-widget/behavior hard stops, including HeaderBar. | **Merged**: [PR #42](https://github.com/Lich5/lich-6/pull/42), confirmed through GitHub on 2026-10-12, merged at `2026-10-12T14:08:58Z` as `bea51ac3522d894ecc33c39abcccdc00a8017661`. Includes the bounded stale-generation test-helper retry from head `857a8e04ee189444b94fcae7ae35192e3ef8c207`. Whole-script/native-window acceptance is not claimed. |

Post-merge synchronization, 2026-10-12: fetched `origin`, switched from the clean
PR 1 branch to `main`, and fast-forwarded to the merge commit above. Verified
`main` and `origin/main` have zero divergence and contain the reviewed PR head.
The tree was clean before the documentation-only status update. No feature
branch was deleted. The owner then authorized PR 2's first implementation slice;
the new branch preserved those uncommitted documentation updates.

PR 2 post-merge synchronization, 2026-10-12: fetched `origin`, switched from the
clean feature branch to `main`, and fast-forwarded to `bea51ac3522d894ecc33c39abcccdc00a8017661`.
Verified zero divergence between `main` and `origin/main` and inclusion of the
reviewed PR head. The tree was clean before this documentation-only update;
the feature branch was retained. GitHub reports successful RSpec, RuboCop,
Ruby syntax, JavaScript renderer and Chrome integration checks. The final local
test-helper validation passed with seed `57467`: **9,107 examples, zero failures,
17 browser-only pending**; focused RuboCop and diff checks also passed.

Both approved CSS decoration PRs are merged; no implementation remains in that
two-PR plan. The next authorized branch is tracked below. The
[measurement/acceptance report](webui-css-decoration-acceptance.md) retains the
acceptance boundaries. The 8,192-character
bound is retained: all 71 payloads from 33 pinned scripts fit, with a measured
maximum of 6,230. Dynamic settings can still exceed it. The subsequent HeaderBar
slice accepts tpick's headers; PR 3 now accepts manatimer Display. Do not reopen excluded
Builder expansion or infer whole-script acceptance.

### Refreshed GTK compatibility work tracker

Read-only source survey, 2026-10-12: fetched EO `origin/master` at
`c4a96840ea2a29a445fd797c7baec0b012b0dd12` and mirror `origin/main` at
`2fa28f1e540e97c468af88bbc8c432d3cebf8755`. Excluding EO test fixtures, 2,590
committed script files yielded 230 GTK-related lexical candidates (51 EO, 179
mirror); 113 changed since 2025-10-12 (27 EO, 86 mirror). Fourteen candidates
changed since the cached source baselines. Mirror dates describe observed
snapshots, not author release dates. HeaderBar appears in 12 scripts, 11 updated
within the year. tpick v48 was last observed changing on October 6; manatimer
v0.1 on June 22. Both still match their cached source versions.

Implementation slices 1, 2 and 3 below are merged. PR 4 is implemented locally;
validation is recorded below. Other rows remain proposals,
including the owner-deferred image-window follow-up. Each future branch
starts from synchronized `main` after its predecessor merges.

| Proposed PR | Included features / methods / widgets | Status |
| --- | --- | --- |
| 1. HeaderBar/titlebar and complete default tpick setup | HeaderBar/titlebar lifecycle; signed Grid origins and live rebasing; bounded class-qualified label foreground cues; Align constants and Label word wrapping; empty/live notebooks; Grid tab-panel layout. Original settings/profile/default/save and information/message/statistics/close flows. | **Merged**: [PR #43](https://github.com/Lich5/lich-6/pull/43), confirmed 2026-10-12; `cd10f7b2`. Includes transactional adapter attachment and HeaderBar documentation follow-ups. |
| 1b. Optional tpick image windows | Borderless/transient windows, overlay label sizing/markup and image fallback/cleanup; reusable methods only. | **Owner deferred** from PR 1. Generic decoration toggling is supplied by PR 2; transient/image behavior remains unstarted. Default `Show Images = No` setup is covered in PR 1. |
| 2. Progress rendering and manatimer overlay semantics | Consistent core progress appearance and dimensions independent of CSS recognition; progress fraction/text visibility; aligned overlay layers and live pass-through; progress pointer events and Event mask alias; decoration toggle via existing presentation. No CSS grammar expansion. | **Merged**: [PR #48](https://github.com/Lich5/lich-6/pull/48), confirmed 2026-10-12; `d7726455`. PR 3 adds complete setup acceptance with saved-position fixture data. |
| 3. Best-effort monitor geometry and named cursors | One shared host geometry request; bounded Display/Screen/Monitor projections for manatimer and gemstonev; host-owned placement and explicit sizing fallback; named cursor hints for gemstonev/highlight-manager. No pointer polling or device emulation. | **Merged**: [PR #54](https://github.com/Lich5/lich-6/pull/54), confirmed 2026-10-14; `5f2d0e86`. Acceptance and platform limits below. |
| 4. Owner-bound GLib scheduling | Timeout.add/add_seconds, Idle.add and Source.remove through bounded shared scheduling and the existing owner dispatcher; repository v2.76 timer acceptance; sail2 source-failure and explicitly repaired setup/save/close acceptance; inherited container sensitivity and retained Window hide/show; bounded CENTER/set_position aliases and gemstonev difficulty/timer acceptance. | **Open as [PR #55](https://github.com/Lich5/lich-6/pull/55); review follow-ups implemented and validated locally**, not staged/committed/pushed. Owner approved bounded schedule/cancel, then sensitivity/window visibility expansion. Sail2 startup race remains explicit; no full-script compatibility claim. |
| 5. Source acceptance refresh | Re-pin changed eloot/Bigshot sources; preserve original source failures; bounded abyssx/compass_and_wings checks. Repository v2.76 scheduling acceptance moved into PR 4; older baseline fixtures remain. | **Not started; proposed** |
| Separate script PR: sea-charts native WebUI conversion | Reuse native map's shared rendering/interaction primitives; preserve sailing/map/plugin logic. No shim Layout/pointer expansion. | **Proposed; not started**. Implementation repository and acceptance to be scoped separately. |

#### PR 4 implementation and validation, 2026-10-14

- Fetched origin, confirmed main/origin/main both `5f2d0e86` with zero divergence,
  and created `feat/webui-owner-glib-scheduling`. Preserved both existing
  documentation edits (backup `/private/tmp/pr4-preserved-docs.patch`).
- Added `WebUI.callback_scheduler(owner:)` with retained schedule/cancel handles.
  One default-thread-group timing worker enqueues on the existing owner dispatcher;
  monotonic deadlines, per-owner/host limits, no overlap or missed-tick backlog,
  and owner/service shutdown are covered. Retiring a completed tick cannot cancel
  the next queued tick. Session cleanup cancels only its own handle's sources.
- Added script-local GLib Timeout.add/add_seconds, Idle.add and Source.remove,
  with script/viewer attribution, pause behavior and existing error/model boundaries.
  No native GLib loading, priority/IO emulation, per-timer worker or script-specific
  product branch was introduced. The owner then expanded PR 4 to generic inherited
  sensitivity and retained window hide/show (contract 2.21.0). Renderer inheritance
  and event intake enforce disabled ancestors without overwriting child settings.
  Window visibility uses the shared presentation record: macOS NSWindow and owned
  Windows HWND implementations, browser/Linux content-only fallback with notice.
- Cached repository v2.76 Setup executes unchanged: captured Script.start,
  timer replacement/cancellation, actual ten-second re-enable and cleanup pass.
  Older repository fixture remains separately identified as historical acceptance.
- Sail2's original nil/Idle/nil-wait startup race is preserved as a deterministic
  negative case. The positive UI harness changes only the initial nil to :pending.
  Creation, inherited sensitivity, captured save and original hide/destroy Close
  pass. A separate generic fixture verifies timed hide/show retains the same page
  handle and input draft. No sail2 source or sailing logic was repaired.
- Full RSpec: **9,188 examples, zero failures, 27 explicit-browser pending**,
  seed `21101`. Focused expansion: **172 examples, zero failures, six pending**,
  seed `48484`; final Bigshot/runtime regression: **48 examples, zero failures**,
  seed `21101`. The Bigshot test now publishes Custom Fog's enabled state before
  sending its edit, matching the browser and preserving disabled-event refusal.
- Full RuboCop: **1,327 files, no offenses**. JavaScript: **162 tests passed**.
  Chrome: **three scheduling/source acceptance examples, zero failures**, seed `10833`;
  corrected Bigshot controls/boons/profile regression: **one example, zero failures**,
  seed `36137`.
- Native macOS WebKit: repository **one example, zero failures**, seed `50025`;
  expanded sail2 setup/save/close **one example, zero failures**, seed `36709`;
  retained hide/timed-show/input **one example, zero failures**, seed `58280`.
  The actual NSWindow disappeared and returned with its draft. The universal
  arm64/x86_64 helper rebuilt successfully. Windows visibility has provider-test
  coverage only; browser/Linux fallback hides content while browser chrome remains.
- Browser CI includes all three new scenarios. `git diff --check` passes. No staging,
  commits, pushes or dependency installation. Scope exceptions used: the owner's
  bounded shared schedule/cancel approval and explicit expansion to inherited
  sensitivity and top-level window visibility. Existing work remains preserved.

Logs: `/private/tmp/pr4-expansion-full.log`,
`/private/tmp/pr4-expansion-focused.log`, `/private/tmp/pr4-expansion-regression.log`,
`/private/tmp/pr4-expansion-rubocop.log`, `/private/tmp/pr4-expansion-js.log`,
`/private/tmp/pr4-expansion-chrome.log`, `/private/tmp/pr4-expansion-bigshot-chrome.log`,
`/private/tmp/pr4-webkit-repository.log`,
`/private/tmp/pr4-expansion-webkit-sail2.log`,
`/private/tmp/pr4-expansion-webkit-visibility.log`, `/private/tmp/pr4-native-build.log`.
Native checks reused `/private/tmp/pr3-native-webkit.rb` with the actual WKWebView host.

#### PR #55 review follow-up, 2026-10-14

- Reviewed CodeRabbit's one finding at `3f3f699e`: the renderer dropped lifecycle
  notifications for disabled/hidden controls while the runtime accepted them.
  Added lifecycle exemptions with a contract-parity regression; existing geometry
  notification exemption remains. Tests cover context-menu dismissal after disable
  or hide, focus/blur/pointer notification delivery, and blocked ordinary interaction.
- Added `Gtk::WindowPosition::CENTER` and `Window#set_position` as aliases of the
  existing `:center` / `set_window_position` fallback. Other position modes remain
  unsupported; host placement is not guaranteed. No shared-core extension.
- Added exact cached gemstonev difficulty-window source (1754–1796), unchanged.
  Tests cover three difficulty buttons, disabling them, captured game command,
  repeating 50ms wait, one handoff when synthetic game data arrives, and retirement.
  Browser acceptance captures the main-window handoff and closes the fixture;
  main/game-window and whole-script compatibility remain unclaimed.
- Validation: full RSpec **9,193 examples, zero failures, 28 explicit-browser
  pending**, seed `25723`; focused **136 examples, zero failures, eight pending**,
  seed `34517`; full RuboCop **1,327 files, zero offenses**; JavaScript **166 passed**.
  Chrome **four examples, zero failures**, seed `54375`; native macOS WebKit
  gemstonev difficulty selection/handoff **one example, zero failures**, seed `946`.
  Full RSpec passed before a whitespace-only RuboCop alignment correction.
- Prior PR #55 CI was green; CodeRabbit docstrings passed at 76.12% against 60%.
  These follow-ups have local validation and await owner publication/review.
  No additional shared-core extension or script/game logic change was required.
  Existing work preserved; no staging, commits or pushes.

Logs: `/private/tmp/pr55-review-focused.log`, `/private/tmp/pr55-review-full.log`,
`/private/tmp/pr55-review-rubocop.log`, `/private/tmp/pr55-review-js.log`,
`/private/tmp/pr55-review-chrome.log`, `/private/tmp/pr55-review-webkit.log`.

<details>
<summary>Exact PR #55 follow-up changed files</summary>

```text
docs/webui-css-decoration-fallback-brief.md
docs/webui-integration.md
docs/webui-review-readiness.md
lib/common/script_scope/gtk/boot.rb
lib/common/script_scope/gtk/widgets.rb
lib/webui/assets/app.js
spec/README.md
spec/fixtures/webui/README.txt
spec/fixtures/webui/scheduling.json
spec/lib/common/script_scope_scheduling_acceptance_spec.rb
spec/lib/common/script_scope_widgets_spec.rb
spec/lib/webui/contract_foundation_spec.rb
spec/lib/webui/runtime_spec.rb
spec/webui/browser.spec.cjs
spec/webui/webui_renderer_test.cjs
```

</details>

<details>
<summary>PR 4 exact changed-file inventory (including preserved documentation edits)</summary>

```text
.github/workflows/webui_tests.yaml
docs/webui-css-decoration-fallback-brief.md
docs/webui-integration.md
docs/webui-review-readiness.md
lib/common/script_scope/gtk/boot.rb
lib/common/script_scope/gtk/scheduling.rb
lib/common/script_scope/gtk/session.rb
lib/common/script_scope/gtk/widgets.rb
lib/webui.rb
lib/webui/assets/app.js
lib/webui/contract.rb
lib/webui/native/macos/Host.swift
lib/webui/runtime.rb
lib/webui/scheduler.rb
lib/webui/window_presentation.rb
spec/README.md
spec/fixtures/webui/README.txt
spec/fixtures/webui/scheduling.json
spec/lib/common/script_scope_builder_remaining_spec.rb
spec/lib/common/script_scope_scheduling_acceptance_spec.rb
spec/lib/common/script_scope_scheduling_spec.rb
spec/lib/common/script_scope_widgets_spec.rb
spec/lib/webui/adapter_factory_spec.rb
spec/lib/webui/contract_foundation_spec.rb
spec/lib/webui/contract_spec.rb
spec/lib/webui/runtime_spec.rb
spec/lib/webui/scheduler_spec.rb
spec/lib/webui/server_spec.rb
spec/lib/webui/window_presentation_spec.rb
spec/webui/browser.spec.cjs
spec/webui/webui_native_host_test.cjs
spec/webui/webui_renderer_test.cjs
```

</details>

Owner scope decisions, 2026-10-13: `map` modernizes `xnarost`, which modernizes
`narost`. Native `map` is already converted (not a claim of EO publication).
`xnarost` receives no further shim work; unsupported GTK calls retain the standing
migrate-to-WebUI refusal. `sea-charts` is a native conversion candidate. Header
age alone does not determine priority: consider lineage, EO ownership, downloads
and community activity. No popularity figures were obtained in this assessment.

The original six distinct Display consumers reconcile as follows:

| Category | Scripts | Remaining shim scope |
| --- | --- | --- |
| Monitor geometry (3) | map, manatimer, gemstonev | manatimer and gemstonev only |
| Pointer queries (2) | xnarost, sea-charts | None; no polling-pointer compatibility project |
| Cursor creation (1 additional, plus overlap) | highlight-manager; gemstonev also uses cursors | Generic named cursor appearance only |

Cached-source runtime probes, 2026-10-13: GTK map stops at a menu `show` signal;
sea-charts stops in queued setup at `size_allocate`. xnarost first fails in its
own MapData lookup (`@@data` initialized, `@data` returned); its isolated GUI
setup also refuses `size_allocate`. Independent probes confirm missing Layout,
horizontal scroll/viewport measurements, image metadata and interaction APIs.
Native map's browser-side dragging does not itself expose Ruby pointer polling.
Thus pointer reuse alone would not make these GTK scripts work. Tests used
isolated game/settings fixtures and no native GTK; they do not claim live-game
acceptance. Temporary evidence: `/private/tmp/gtk-map-shim-probe_spec.rb`,
`/private/tmp/gtk-map-shim-probe.log`, `/private/tmp/map-cohort-shim-probe_spec.rb`
and `/private/tmp/map-cohort-shim-probe.log` (two cohort examples, zero failures
in the final diagnostic run). Sources remain under
`/private/tmp/webui-freshness-survey`, pinned to the survey revisions above.

#### PR 3 proposal: geometry and named cursors

Owner-approved bounded shared-core changes, implemented locally on 2026-10-13:

- One owner/viewer-scoped `monitor_geometry` request, selecting the active host
  screen by default, or requesting primary/point selection. The host supplies
  a rectangle and availability/provenance; platform providers sit behind that
  same contract. Use available macOS/Windows/Linux host facilities, without
  exposing native handles or adding a shim service/dispatcher. Unsupported
  selection falls back to the active/available screen with an explicit notice.
  If no measurement is available, return unavailable; the shim may reuse its
  existing declared nominal 1024x768 sizing hint, never label it a real monitor.
- Project only the observed geometry chains: `Gdk::Display.default`,
  `default_screen.get_monitor_at_point(x, y)`, `get_monitor_geometry(index)`,
  `primary_monitor.geometry`, and rectangle x/y/width/height. Keep monitor tokens
  owner-bound. Existing window move requests remain host-owned best effort,
  with host clamping where supported and documented host-default placement
  otherwise. Do not promise exact placement or change script calculations:
  manatimer ignores monitor origins; gemstonev uses width/height for sizing.
- A validated named cursor presentation property through core/adapter/renderer.
  Bounded `Gdk::Cursor.new`/`new_from_name`, `:hand2`/`HAND2` aliases and
  `set_cursor`/`cursor=` project to a widget/window-scoped browser hint. Support
  `default`, `pointer`, `cell`, and `copy`; unavailable names/host rendering use
  the documented default cursor. Any window facade exposed for this purpose
  supports cursor assignment only, not native handles or device/pointer queries.
  No custom cursor images, warping, pointer grabs or global cursor changes.

Cursor evidence: gemstonev uses pointer normally, cell for execute mode and copy
for ability targeting; labels also describe the modes. Its unguarded assignment
must not interrupt game logic. highlight-manager requests a hand over clickable
names, guards capability checks and rescues failures; lookup does not depend on
cursor appearance. This supports a generic presentation mapping/fallback, not
unconditional acceptance of other Gdk operations.

Acceptance: unchanged cached manatimer setup through geometry, move, keep-above
and subsequent progress updates; gemstonev's exact geometry/sizing and cursor
call sites; highlight-manager's guarded cursor helper. Verify selector/fallback
behavior, signed origins, owner/viewer isolation, teardown and unsupported-call
refusals. Exercise real cursor appearance and geometry/placement in macOS WebKit;
record Windows/Linux native validation separately from provider/unit tests.
Whole gemstonev/highlight-manager compatibility is not claimed. Real GTK,
non-GUI script logic, CSS grammar, map pointer polling and optional tpick image
windows remain excluded. Reuse the existing owner dispatcher throughout.

PR 3 implementation and validation, 2026-10-13:

- Fetched origin; fast-forwarded main from `d7726455` to `585bb871` (documentation
  PR #50), verified zero divergence, and created `feat/webui-monitor-geometry-cursors`.
  Existing edits to this handoff and the fallback brief were preserved.
- Contract 2.20.0 adds validated cursor hints and bounded monitor snapshots in
  configure events. One core `monitor_geometry` request selects owner/viewer
  measurements or pre-viewer host discovery. AppKit, Windows Forms/Win32 and
  optional XRandR providers share validation, selectors and explicit fallback.
  Viewer snapshots clear on detach/disconnect. Existing owner dispatch is reused.
- Shim Display/Screen/Monitor/Rectangle and cursor-only window facades implement
  the source call shapes. Named cursor aliases, inherited styling, nil reset,
  cross-owner/teardown refusals and unsupported device APIs are covered. macOS
  move requests clamp to an available screen's visible frame.
- Full RSpec: **9,164 examples, zero failures, 24 browser-only pending**, seed
  `18463`; changed Ruby files: **16 inspected, no RuboCop offenses**. JavaScript:
  **161 tests passed**. Explicit Chrome selection: **13 examples, zero failures**.
  The new browser case is included in the existing Chrome CI selection.
- Native WebKit: both acceptance examples passed in the rebuilt universal host.
  Cursor pointer/cell/copy/reset callbacks and native **2560x1440** measurement
  round-tripped; full unchanged manatimer setup, `01:00`/50% update, right-click
  borderless toggle and closure passed. Browser computed-style tests verify
  cursor inheritance/reset. A further native run requested `[-65000, 65000]`,
  verified the window remained visible and measured its clamped position as
  `[0, 933]`. Build contains both arm64 and x86_64 architectures.
- Windows/Linux provider fixtures pass, but native validation on those systems
  and physical multi-monitor arrangements remain open. Signed topology and
  fallback cases use deterministic fixtures. Missing manatimer saved position,
  ignored monitor origins, CSS pulse colors and whole gemstonev/highlight-manager
  behavior remain outside this acceptance.

PR 3 review follow-up, 2026-10-14: both minor review items addressed locally.
The cached monitor-token branch now uses block-local `next`, and monitor discovery
explicitly requires JSON. The regression verifies 40 identical point requests
reuse one token without exhausting the 32-point bound, while a different point
gets a distinct token. Focused geometry/cursor specs: **10 examples, zero failures,
one explicit-browser pending**, seed `1300`. RuboCop: **3 files inspected, no
offenses**. Logs: `/private/tmp/pr3-review-focused.log` and
`/private/tmp/pr3-review-rubocop.log`. Status remains ready for owner review;
existing work preserved, no staging, commits or pushes.

Temporary validation logs: `/private/tmp/pr3-full-final.log`,
`/private/tmp/pr3-rubocop-final.log`, `/private/tmp/pr3-node-all.log`,
`/private/tmp/pr3-chrome.log`, `/private/tmp/pr3-webkit-cursors.log`,
`/private/tmp/pr3-webkit-manatimer.log`, `/private/tmp/pr3-webkit-clamp.log`,
`/private/tmp/pr3-native-build.log`.
The native-window harness is `/private/tmp/pr3-native-webkit.rb`; retained source
evidence is `spec/fixtures/webui/geometry-cursors.json` and `manatimer.json`.
No real GTK, script/game logic edits, staging, commits or pushes. Scope exceptions
used: only the owner's approved bounded geometry and named-cursor extensions.

PR #54 merge and synchronization, 2026-10-14: GitHub confirms merge at
`2026-10-14T15:16:36Z`, merge commit `5f2d0e86c759572d424da2ed3093b22c2db998f3`.
Fetched origin, switched from the clean feature branch to main, and fast-forwarded;
`HEAD == main == origin/main`, zero ahead/behind. The feature branch is retained.
CR's sole major finding was a false positive: `Screen#initialize` in `style.rb`
already binds `Gtk.session`, and boot loads it before reopening the class in
`display_geometry.rb`. Verification at PR head: 13 examples, zero failures,
two browser-only pending, seed `8019`; docstring coverage passed at 94.87%.
No product correction or remote reply was made. This sync changes only this
handoff and the fallback brief; `git diff --check` is the documentation check.
No tests rerun for the sync, no staging, commits or pushes.

<details>
<summary>PR 3 exact changed-file inventory (including preserved documentation edits)</summary>

```text
.github/workflows/webui_tests.yaml
docs/webui-css-decoration-acceptance.md
docs/webui-css-decoration-fallback-brief.md
docs/webui-integration.md
docs/webui-review-readiness.md
lib/common/script_scope/gtk/boot.rb
lib/common/script_scope/gtk/display_geometry.rb
lib/webui/adapter.rb
lib/webui/assets/app.css
lib/webui/assets/app.js
lib/webui/contract.rb
lib/webui/monitor_geometry.rb
lib/webui/native/macos/Host.swift
lib/webui/native/macos/window.js
lib/webui/page.rb
lib/webui/runtime.rb
lib/webui/service.rb
spec/README.md
spec/fixtures/webui/README.txt
spec/fixtures/webui/geometry-cursors.json
spec/fixtures/webui/manatimer.json
spec/lib/common/script_scope_css_corpus_spec.rb
spec/lib/common/script_scope_geometry_cursor_spec.rb
spec/lib/common/script_scope_manatimer_spec.rb
spec/lib/webui/adapter_spec.rb
spec/lib/webui/contract_foundation_spec.rb
spec/lib/webui/contract_spec.rb
spec/lib/webui/monitor_geometry_spec.rb
spec/lib/webui/server_spec.rb
spec/webui/browser.spec.cjs
spec/webui/webui_compact_presentation_test.cjs
spec/webui/webui_native_host_test.cjs
spec/webui/webui_renderer_fixture.cjs
spec/webui/webui_renderer_test.cjs
```

</details>

PR #48 post-merge synchronization, 2026-10-12: GitHub confirms merge at
`2026-10-13T03:21:30Z` as `d7726455642267a4b97f425492e995dcd68ea2ad`, from
head `80ab3dfdca2ce3a2c30fd423f7e497e3a0804ce6`. The owner committed the CR
documentation fix before merging; the feature working tree was clean. Fetched
`origin`, switched to `main`, and fast-forwarded. Verified `main` and `origin/main`
at the merge commit with zero ahead/behind commits. The feature branch is retained.
Only these post-merge documentation updates remain uncommitted. No assistant
staging, commit or push was performed. The subsequent PR 3 geometry/cursor
assessment, later owner approval and local implementation are recorded above.

PR 2 implementation, 2026-10-12: fetched origin, confirmed main at `157c2589`
with zero ahead/behind commits, and created `feat/webui-manatimer-progress-overlay`.
Preserved the existing two post-merge documentation edits. The owner explicitly
approved bounded overlay pass-through and progress pointer-event extensions.
Contract 2.19.0 adds those surfaces; text visibility and window decoration reuse
existing properties. `Adapter#set_overlay_pass_through` preserves identity and
viewer drafts, validates membership/boolean input, and rolls back publication
failure. Overlay removal/destruction clears relationship state. Browser layout
also required progress width requests to be minima rather than fixed allocations.

Owner-approved rendering follow-up: all progress controls now share their base
trough, border and accent fill. Recognized colors override only fill; explicit
dimensions work even with omitted CSS. The default track is 18px high; an enabled
label takes its normal line above the remaining track allocation. Indeterminate
progress retains a moving segment and honors reduced motion. No script-name
branches, CSS grammar expansion or additional contract properties were added.

`spec/fixtures/webui/manatimer.json` pins unchanged v0.1 blocks from mirror
`2fa28f1e540e97c468af88bbc8c432d3cebf8755`, source SHA-256
`ac33cc5b04bb6d4185063b552c1dcc8290b5cdfe752ba9ea36402f65a4f9bf2f`.
The partial harness runs controls (50–75), providers (80–96), countdown (176–182)
and cleanup (101–116), using isolated settings and bounded queue waits. The full
At PR 2, 49–97 setup remained a negative test at `Gdk::Display`, line 76; PR 3
supersedes that result with full setup acceptance above. Restoration
76–79 is explicitly excluded from positive acceptance. No game loop or pulse
catcher runs. Missing saved position and clamping that ignores monitor x/y are
source limitations, not shim repairs. Red/green CSS remains omitted. Generic
borderless support does not complete deferred tpick image-window acceptance.

Final validation (host rubystd Ruby 4.0.5, seed 57467):

- Full RSpec: **9,154 examples, zero failures, 23 browser-only pending**.
- Explicit Chrome CI selection, including manatimer and core progress sizing: **19 examples, zero failures**.
- Full RuboCop: **1,318 files, zero offenses**.
- Renderer suites: **159 tests, zero failures**.
- `git diff --check`: clean.

Native macOS WebKit: **one explicit fixture example, zero failures**;
visually verified centered `01:00` over 50% progress, native titlebar removal and
restoration through the original right-click callback, pass-through disabled
blocking that callback, and Finish closing the owned host. A temporary harness
opened the same source-derived browser fixture through production `Service#open`;
no native host or script source modification was needed. The temporary harness was
`/private/tmp/manatimer-webkit-acceptance.rb`. Logs are `/private/tmp/pr2-full.log`,
`pr2-chrome-full.log`, `pr2-rubocop.log`, `pr2-renderer.log` and `pr2-webkit.log`.
An initial full run correctly exposed the moved tpick image-mode refusal; its
negative acceptance now asserts `transient_for=` at line 2751. Chrome also exposed
fixed progress-width allocation, repaired and verified before final validation.

Rendering follow-up WebKit acceptance: **one explicit core fixture example,
zero failures**, through `/private/tmp/progress-sizing-webkit.rb`. Visually
compared plain/colored 18/24/36px tracks, label allocation, the 18px default,
animated indeterminate progress and color removal with unchanged dimensions.
Chrome additionally checks exact bounds and reduced-motion behavior. Its provider
lifecycle case still restores default height/fill after omission or removal.
Follow-up logs: `/private/tmp/pr2-sizing-browser.log`, `pr2-sizing-webkit.log`,
`pr2-sizing-full.log`, `pr2-sizing-renderer.log` and `pr2-sizing-rubocop.log`.

PR 2 changed-file inventory (includes preserved post-merge documentation edits):

```text
.github/workflows/webui_tests.yaml
docs/webui-css-decoration-fallback-brief.md
docs/webui-integration.md
docs/webui-review-readiness.md
lib/common/script_scope/gtk/displays.rb
lib/common/script_scope/gtk/menus.rb
lib/common/script_scope/gtk/widgets.rb
lib/webui/adapter.rb
lib/webui/assets/app.css
lib/webui/assets/app.js
lib/webui/contract.rb
spec/README.md
spec/fixtures/webui/README.txt
spec/fixtures/webui/manatimer.json
spec/lib/common/script_scope_manatimer_spec.rb
spec/lib/common/script_scope_tpick_setup_spec.rb
spec/lib/webui/adapter_spec.rb
spec/lib/webui/browser_integration_spec.rb
spec/lib/webui/contract_foundation_spec.rb
spec/lib/webui/contract_spec.rb
spec/lib/webui/server_spec.rb
spec/webui/browser.spec.cjs
spec/webui/webui_renderer_test.cjs
```

Scope exceptions: the owner-approved overlay pass-through and progress
pointer-event core extensions, and generic core progress rendering correction.
Existing owner dispatch, non-GUI logic, CSS
omission and real-GTK exclusion remain intact. No assistant staging, commit or push.
Owner publication subsequently completed in PR #48, as recorded above.

PR #43 post-merge synchronization, 2026-10-12: GitHub confirms merge at
`2026-10-12T16:43:09Z` as `cd10f7b29e9d9b5319702881f17eb9bcea18aecf`, from
head `b876c2a119c3e3ca73affcc88b467d848218c130`. The feature working tree was
clean. Fetched `origin`, switched to `main`, and fast-forwarded; verified
`HEAD == main == origin/main` with zero ahead/behind commits. The merged tree
matches the reviewed feature head exactly. The feature branch is retained.

Final-head GitHub checks passed: Ruby tests/syntax, RuboCop, JavaScript renderer,
Chrome integration and PR title. CodeRabbit reports review skipped because
automatic reviews are disabled; no revised remote docstring percentage is
asserted. Existing local validation below remains applicable; no code tests were
rerun for this synchronization and documentation-only update. Only this tracker
and the brief were edited afterward, left unstaged. No staging, commit or push.

PR 1 implementation boundaries: HeaderBar composes existing boxes, labels and
buttons; signed Grid positions are translated uniformly into positive shared
placements. Table's unsigned coordinate rules remain unchanged. The owner approved
`Adapter#layout_grid` for atomic column/placement updates without replacing handles,
and empty `tabs.names` with no selectable page until populated. Contract 2.18.0
records the latter. Notebook appends publish names before attaching live children.
The viewport CSS preserves grid tab panels instead of changing them into flex stacks.

Class-qualified label foreground rules are a bounded, reusable cue surface:
`label.<class>` with optional descendant type/`#name` ancestors and supported literal
colors. No script name, required-setting class name, DOM selector or raw stylesheet
is hardcoded or forwarded to the renderer. Provider priority, selector specificity,
source order, class/ancestor changes, reload/removal and owner cleanup determine the
typed `foreground`; other CSS remains omitted. Progress styling remains separate.

Pinned evidence: `spec/fixtures/webui/tpick-titlebar.json` retains unchanged methods,
constants, setup data/defaults/tooltips and stylesheet, each hashed with original
line ranges, from mirror `2fa28f1e540e97c468af88bbc8c432d3cebf8755` (v48).
`script_scope_tpick_setup_spec.rb` supplies character/spell/inventory answers and
isolated settings files. It runs original GUI and persistence code, not top-level
game initialization. Rogue, Warrior, Bard and Wizard settings construct; the default
information window populates queued statistics, updates messages and closes cleanly.
Profile Load, Defaults and Save execute original callbacks. Scan's game commands
and real gameplay are not executed. Real GTK remains excluded from production.

Explicit source limits: spell-less Monk/Paladin settings access a missing
`Spells Main` grid at original line 2926. Negative tests retain that source defect;
no nil suppression or script-specific repair is added. Optional `Show Images`
construction now passes `Window#decorated=` through PR 2 and refuses
`Window#transient_for=` at line 2751; further transient
window and overlay/image requirements belong to owner-deferred PR 1b. These are not
claims of universal whole-script or native GTK visual equivalence.

Validation for expanded PR 1 (2026-10-12), retained host `rubystd` Ruby 4.0.5:

- Full RSpec, seed `57467`: **9,135 examples, zero failures, 21 browser-only pending**.
- Focused explicit Chrome run (HeaderBar and complete tpick setup): **24 examples,
  zero failures**, including four browser scenarios and a Grid alignment assertion.
- Full explicit Chrome browser suite, seed `57467`: **21 examples, zero failures**.
- Full RuboCop: **1,313 files, no offenses**. Renderer JavaScript: **157 tests,
  zero failures**. `git diff --check` passed.
- Native macOS WKWebView settings: profile loading, Defaults, required red label,
  entry editing, original Save to a temporary file and Close/cleanup passed.
  A native layout check exposed viewport CSS flattening Grid panels into stacks;
  the fix was visually rechecked and the native edit/save/close case passed again.
- Native information: Messages, populated nested Stats, Settings, return to Main,
  original Start callback and close/save cleanup passed (**one example, zero failures**).
  An earlier combined native run lost reliable UI control after replacing its host;
  that information check was interrupted/closed and failed its unexecuted Start
  assertion. The isolated rerun above passed; this is not counted as a clean combined run.

Review follow-up, 2026-10-12: the Grid attachment rollback finding is addressed.
An `add(child)` failure restores the prior logical origins, exact row/column
geometry and placements in both the shim and adapter; an inserted child is
detached, and the original error is re-raised. Detached child placement is restored
even when it extends beyond the old grid width. Existing handles, bindings and
input values survive, and a subsequent attachment succeeds. No shared-core API
extension was needed.

Three injected live failures reproduced the defect before the fix: adapter attach,
refused insertion and failure after insertion. All now pass, along with a fourth
regression for an unmaterialized grid (no handle allocation) and a fifth for
rollback at the placement-map capacity bound. Post-fix focused
HeaderBar/tpick/adapter acceptance with Chrome: **62 examples, zero failures**,
seed `57467`. Focused RuboCop: **two files, no offenses**; diff check passed.
Full post-fix RSpec, seed `57467`: **9,140 examples, zero failures, 21 browser-only
pending**. This follow-up
changes only `lib/common/script_scope/gtk/layout.rb`,
`spec/lib/common/script_scope_header_bar_spec.rb` and this tracker; prior work is
preserved. No staging, commit or push.

PR #43 review follow-up, 2026-10-12 (reviewed head `6b72f814`):

- Made `Adapter#attach` transactional when post-insertion slot assignment or
  render scheduling raises. It removes the inserted child, clears its adapter
  parent/slot, restores sibling slots and re-raises, before the shim sets its
  Ruby parent. Handles, bindings and values remain available for retry.
- Two scheduling-failure regressions (grid and named tabs) failed before the
  change and now pass. They verify membership, slots, retained binding/value,
  cleared publication-pending state and successful retry with real scheduling.
- Documented all **11 HeaderBar methods**, including seven previously missing
  method comments, with behavior and relevant YARD argument/return/exception
  details. RSpec files remain excluded from docstring work. CodeRabbit reported
  **53.13% against 60%** on the published head; its exact revised percentage
  requires its next review after owner publication and is not claimed locally.
- Restored both resolver fixture addresses to `172.17.0.1`; that file now has
  no net diff from `main`. These were accidental version-replacement edits.

Focused validation: **71 examples, zero failures, two browser-only pending**,
seed `57467`; focused RuboCop **four files, no offenses**. Full Chrome browser suite: **21
examples, zero failures**; full RuboCop: **1,313 files, no offenses**. Full RSpec,
seed `57467`: **9,142 examples, zero failures, 21 browser-only pending**.
This follow-up changes only `lib/webui/adapter.rb`,
`lib/common/script_scope/gtk/header_bar.rb`, `spec/lib/webui/adapter_spec.rb`,
`spec/lib/common/bind_host_resolver_spec.rb` and this tracker. The owner explicitly
authorized the shared adapter fix. No API expansion, staging, commit or push.

Merged PR #43 changed-file inventory relative to its base (including earlier slices):

```text
docs/webui-css-decoration-acceptance.md
docs/webui-css-decoration-fallback-brief.md
docs/webui-integration.md
docs/webui-review-readiness.md
lib/common/script_scope/gtk/boot.rb
lib/common/script_scope/gtk/header_bar.rb
lib/common/script_scope/gtk/layout.rb
lib/common/script_scope/gtk/session.rb
lib/common/script_scope/gtk/style.rb
lib/common/script_scope/gtk/widgets.rb
lib/webui/adapter.rb
lib/webui/assets/app.css
lib/webui/assets/app.js
lib/webui/contract.rb
lib/webui/validator.rb
spec/README.md
spec/fixtures/webui/README.txt
spec/fixtures/webui/tpick-titlebar.json
spec/lib/common/script_scope_css_corpus_spec.rb
spec/lib/common/script_scope_header_bar_spec.rb
spec/lib/common/script_scope_style_spec.rb
spec/lib/common/script_scope_tpick_setup_spec.rb
spec/lib/webui/adapter_spec.rb
spec/lib/webui/contract_foundation_spec.rb
spec/lib/webui/contract_spec.rb
spec/lib/webui/server_spec.rb
spec/lib/webui/validator_spec.rb
spec/webui/browser.spec.cjs
```

Scope exceptions used: owner-approved atomic grid-layout and empty-notebook shared
extensions, plus the explicitly authorized required-setting cue surface. Cached
script evidence was read only; real GTK, non-GUI script logic and optional image
windows remain outside this implementation. No staging, commit or push.
Completed slices: PR 2 progress rendering/overlay semantics merged as PR #48;
PR 3 geometry/named cursors merged as PR #54. PR 4 owner-bound scheduling is
implemented locally; see the current tracker and validation record. PR 5 source
acceptance refresh remains proposed. Sail2 sensitivity/top-level hide were approved
and included in PR 4; its original startup race remains. PR 1b optional image
windows remains deferred.

PR 2 first-slice inventory, 2026-10-12:

- `lib/common/script_scope/gtk/style.rb`: explicit provider states; bounded
  unrecognized strings become inert omitted decoration; only recognized providers
  contribute progress effects. Reloads reset or reveal remaining recognized effects.
- `lib/common/script_scope/gtk/session.rb`: optional receiver attribution in the
  existing degradation helper; CSS-load omission reports once per owner/session.
- `spec/lib/common/script_scope_style_spec.rb`, `spec/lib/common/script_scope_widgets_spec.rb`
  and `spec/webui/browser.spec.cjs`: state transitions, authored/default restoration,
  provider priority, isolation, cleanup, hard stops and Chrome reset/recovery.
- This tracker, the fallback brief, integration guide and `spec/README.md` describe
  the partial implementation and remaining scope. The audit JSON stays historical.

No shared-core, renderer, real GTK, script-source or non-GUI changes. The input
bound is unchanged and has not been reclassified as a measured corpus maximum.
The new cases use synthetic CSS alongside the existing source-derived progress
cases; they do not establish tpick or other whole-script acceptance.

First-slice validation, retained host `rubystd` Ruby 4.0.5, 2026-10-12:

- Before implementation, six focused cases failed on the merged PR 1 behavior.
  Afterward, focused style/widget specs: **90 examples, zero failures, four
  browser-only pending**, seed `35456`.
- Explicit Chrome progress lifecycle: **one example, zero failures**, seed
  `16466`; omission clears custom fill/height, re-recognition restores them,
  fraction/identity and sibling typography remain intact, and the omitted CSS URL
  produces no browser request.
- Full RSpec: **9,048 examples, zero failures, 17 browser-only pending**, seed `1283`.
- RuboCop: **1,307 files, no offenses**. `git diff --check` passed.

Commands used the initialized host gems directly; no dependencies were changed.
No additional renderer suite was needed for unchanged renderer code. This is a
validated local slice, not completion of PR 2 or a native-window/whole-script
acceptance claim. No staging, commit, push or remote PR creation was performed.

PR 2 second-slice inventory, 2026-10-12: continued on the same branch from the
owner's first-slice commit `6ddd5798d8f8a468ab3885481fd6c1510833e551`; the tree was
clean at entry and all prior behavior/documentation was preserved.

- `lib/common/script_scope/gtk/widgets.rb` and `lib/common/script_scope/gtk/displays.rb`:
  move the cached context accessor to Widget and check ownership/lifetime even
  for cached access.
- `lib/common/script_scope/gtk/style.rb`: retain providers on all supported
  widgets, with visible effects only on ProgressBar; add bounded class metadata
  and screen registration/removal APIs; attribute geometry notices only on
  width/height reads. Unknown APIs and widgets still refuse.
- `lib/common/script_scope/gtk/session.rb`: owner-bound, monitor-protected screen
  registry and teardown; share one attributed CSS-omission notice across loads,
  non-progress widget attachments, screen attachments and class additions.
- `spec/lib/common/script_scope_decoration_spec.rb` (new),
  `spec/lib/common/script_scope_style_spec.rb`,
  `spec/lib/common/script_scope_widgets_spec.rb`, `spec/webui/browser.spec.cjs`:
  synthetic shared-context/class/screen coverage and extended Chrome checks.
- Documentation: `docs/webui-integration.md`,
  `docs/webui-css-decoration-fallback-brief.md`, this tracker and `spec/README.md`.

Limits are 64 providers per widget context, 64 screen providers per session, 64
class names per context and 512 characters per class name. Class lists are
independent snapshots; names never become DOM classes. Screen registrations have
no visible effect, including for recognized progress CSS. All registrations and
classes are released on their widget/session lifetime boundary. The existing
session monitor and dispatcher are reused; no shared-core, real GTK, renderer,
script-source or non-GUI changes are included.

Second-slice validation, retained host `rubystd` Ruby 4.0.5, 2026-10-12:

- Focused decoration/style/widget specs: **100 examples, zero failures, four
  browser-only pending**, seed `45614`.
- Explicit Chrome progress lifecycle: **one example, zero failures**, seed
  `43745`. Label contexts and class names do not affect typography or DOM classes;
  a screen registration does not retain progress styling after local removal.
  Existing reload/omission, stable identity, fraction and callback checks pass.
- Full RSpec: **9,058 examples, zero failures, 17 browser-only pending**, seed `11614`.
- RuboCop: **1,308 files, no offenses** after correcting one spacing offense.
  `git diff --check` passed.

Validation used host gems directly, with no dependency changes. The cached audit
was consulted for the API surface; no script-wide or EO PR rescan was performed.
Corpus acceptance, size measurements and native-window certification are not
claimed by these synthetic tests. No staging, commit, push or external write was
performed by the assistant.

PR 2 final evidence slice, 2026-10-12: continued from the owner's clean
`947a9fdcca7ba879ff3d18309d97e4827d8585c6` commit. No product code or bounds changed.

- New `spec/support/build_css_decoration_corpus.rb` reads only the 33 cached,
  pinned source blobs and verifies their hashes. It never evaluates source Ruby.
- New `spec/fixtures/webui/css-decoration.json` retains 71 payloads covering all
  66 load sites, provenance, substitutions, measurements and reviewed excerpts.
- New `spec/lib/common/script_scope_css_corpus_spec.rb` exercises all payloads,
  every observed attachment signature, and CSS-only excerpts from eleven scripts.
  Only spellson/staminabar2 samples are recognized; all others are omitted.
- `spec/lib/common/script_scope_widgets_spec.rb` and `spec/webui/browser.spec.cjs`
  add retained tpick global/label CSS to the controlled Chrome fixture.
- New `docs/webui-css-decoration-acceptance.md` records all 33 dispositions,
  size-limit reasoning, losses, independent blockers and whole-setup limitations.
  Updated this tracker, `docs/webui-css-decoration-fallback-brief.md`,
  `docs/webui-integration.md`, `spec/README.md` and `spec/fixtures/webui/README.txt`.

Final-slice validation, retained host `rubystd` Ruby 4.0.5:

- Corpus acceptance: **46 examples, zero failures**, seed `16010`.
- Chrome with retained tpick CSS: **one example, zero failures**, seed `34274`.
- Full RSpec: **9,104 examples, zero failures, 17 browser-only pending**, seed `65374`.
- RuboCop: **1,310 files, no offenses**.
- Rebuilding the fixture from the pinned sources matches byte-for-byte;
  `git diff --check` passed.

Cross-repository access was limited to the already authorized read-only EO and
mirror source blobs. No scripts, real GTK, non-GUI logic, shared core, renderer,
dependencies, or EO PR state were changed. Full original setup/gameplay and
native-window acceptance remain outside this evidence. No staging, commit, push
or external write was performed by the assistant.

Each PR includes relevant tests and documentation, full RSpec and RuboCop, and
renderer/browser checks where needed. Real GTK, script source changes, non-GUI
logic changes, and the full CSS translator remain excluded. See the
[engineering brief](webui-css-decoration-fallback-brief.md) for the fallback scope
and preserved source evidence. PR 1 alone does not make arbitrary CSS nonfatal.

PR 1 local change inventory:

- Implementation: `lib/common/script_scope/gtk/style.rb`,
  `lib/common/script_scope/gtk/displays.rb`, `lib/common/script_scope/gtk/widgets.rb`,
  `lib/common/script_scope/gtk/session.rb`, `lib/webui/adapter.rb`.
- Tests: `spec/lib/common/script_scope_style_spec.rb` (new),
  `spec/lib/common/script_scope_widgets_spec.rb`, `spec/lib/webui/adapter_spec.rb`,
  `spec/webui/browser.spec.cjs`, `spec/webui/webui_compact_presentation_test.cjs`.
- Documentation: `docs/webui-css-decoration-fallback-brief.md`,
  `docs/webui-integration.md`, `docs/webui-review-readiness.md`, `spec/README.md`.

Only the bounded adapter reset extends shared core, by explicit owner approval.
No product renderer, protocol schema, script source, or non-GUI logic changes.
Source-derived progress checks do not certify whole-script setup or gameplay.
Manatimer's broader CSS, stormsync's decoration call chains and tpick
remain outside PR 1 acceptance; their dispositions belong to PR 2. The 8,192
character input limit remains unchanged after PR 2's measurements above.

PR 1 validation, 2026-10-12, host Ruby 4.0.5:

- Full RSpec: **9,040 examples, zero failures, 17 browser-only pending**, seed `7115`.
- RuboCop: **1,307 files, no offenses**.
- JavaScript renderer/DOM suites: **157 checks passed**, none skipped.
- Explicit Chrome progress lifecycle: **one example passed**, seed `7609`.
  Reload and removal retain fraction and component identity, clear custom color
  and height, leave sibling typography unchanged, and close the fixture window.
- New focused lifecycle regressions reproduced the baseline's missing behavior;
  progress grammar, owner isolation, cleanup, bounds and refusal checks now pass.
- `git diff --check` passed. These checks do not certify native OS-window behavior
  or whole-script/gameplay acceptance. No staging, commit or push was performed.

PR #41 review follow-up, 2026-10-12: the
[destruction-race finding](https://github.com/Lich5/lich-6/pull/41#discussion_r4245486693)
was reproduced. `Widget#destroy` now holds the existing session monitor through
handle retirement and provider detachment; `Window#destroy` also protects its
geometry snapshot. Three regressions failed on the reviewed head and pass with
the fix: direct progress-bar destruction, ancestor-window destruction during a
shared-provider reload, and simultaneous repeated window destruction. The first
two also verify that surviving bars receive the reload and later updates, while
destroyed bars detach and their destroy handler runs once. No exception is hidden
by the product fix, and no dispatcher, renderer or shared-core extension is added.

Follow-up validation under the retained `rubystd` Ruby 4.0.5 session:
focused style/widget specs **85 examples, zero failures, four browser-only pending**
(seed `28035`); full RSpec **9,043 examples, zero failures, 17 browser-only pending**
(seed `6121`); RuboCop **1,307 files, no offenses**; `git diff --check` passed.
RSpec and RuboCop ran directly with the host gems: `bundle exec` could not resolve
the lockfile's exact installed versions. No dependency files or gems were changed.
Browser/renderer checks were not repeated for this Ruby synchronization fix;
the earlier evidence above remains separate. At that validation, the fix was
uncommitted and the assistant performed no staging, commit, push, remote review
reply or thread resolution. The owner subsequently published it and PR #41 merged
as recorded above. The post-merge documentation update passed `git diff --check`;
the dated product validation was not rerun for these status-only edits.

### Other open work

| Item | Status / next decision |
| --- | --- |
| Alias detached-thread ownership repair | Approved as separate work after PR #38; not implemented in this branch. Preserve the owner requirement and address the script's ownership/lifetime. |
| Saved-character edit duplicates | Documentation audit found that `Catalog#update_character` does not perform the duplicate-destination check used by `add_character`. The guide now states the limitation. No behavior change adopted or implemented in this documentation pass. |
| eloot and Bigshot author repairs | Await source updates; retain original negative tests and separately labeled corrected candidates. |
| Windows/Linux native-window acceptance | Still open for actual focus, topmost/opacity where supported, geometry and process cleanup; Linux Chrome transport tests do not certify these. |
| macOS distribution | Signed/notarized helper packaging, older supported macOS and physical Intel acceptance remain release work. Local helper builds are not distribution certification. |
| Arbitrary GTK CSS and internal combo-entry character limits | PR #42 merged: bounded omission, widget/screen/class bookkeeping, cached-cohort measurements and source-derived acceptance. Full CSS translation, whole-script acceptance and combo-entry character-limit expansion remain excluded. |
| stormsync | Excluded from further Builder expansion by owner direction. |
| bigshit2 | Not a target for further expansion by owner direction; do not infer its acceptance from Bigshot. |
| slootbeta and remaining corpus questions | Outside the ten-fixture acceptance proof. Recover the retained child-structure/corpus audit before restating detailed counts or proposing expansion. |
| EO review extraction | Documentation preparation only. No EO base revision, final PR count, extracted branches or independently passing intermediate states established yet. |

## Proposed EO review packages

These packages organize source responsibilities for review. They are **proposed**,
not an adopted PR sequence or an assertion that copying whole directories yields
independently working commits. In particular, the current WebUI facade eagerly
requires its runtime, host, adapter and form helpers. Extraction must carry the
matching require/startup changes at each boundary, not leave dangling imports.

| Package | Source ownership | Dependencies and reviewer evidence |
| --- | --- | --- |
| Core protocol, renderer and owned host | `lib/webui.rb`; `lib/webui/` excluding the adapter and form helpers assigned below. Includes contract/validator, page/tree, registry, runtime/viewers/dispatcher, service/server, authentication/files, renderer, browser/OS hosts and geometry. | Keep schema, server enforcement, renderer and matching tests together. Review `lib/common/script_death.rb` and thread/lifecycle prerequisites against the selected EO base. Core Ruby, renderer, transport, isolation and host tests belong here. |
| Native composition and launcher integration | `lib/api/webui.rb`; `lib/webui/{settings_form,list_settings_form}.rb`; `TreeBuilder` composition helpers; `lib/common/webui_launcher.rb` and its directory. Startup/theme/gem-selection and retained non-GTK GUI/account services require selected hunks from existing files. | Depends on core/host. Include frontend/catalog/authentication/persistence dependencies only where absent upstream. Validate native forms, real entrypoint startup without GTK, launcher cancellation, frontend editing and credential handling. Do not pull unrelated game/runtime changes into this package. |
| Script scope and direct GTK bridge | `lib/common/script_scope.rb`; `lib/common/script_scope/gtk/` except Builder; `lib/webui/adapter.rb`; the relevant binding/cleanup integration in `lib/common/script.rb`. | Depends on core/host. Preserve native/core independence and Script's existing ownership/lifetime contract. Carry direct-widget, loading, model, content and adapter tests. Shared primitives used here belong to core even when first motivated by a legacy script. |
| Optional Builder translation and acceptance | `lib/common/script_scope/gtk/builder.rb`; its boot require; Builder-specific diagnostic handling in `session.rb`; Builder specs, original setup fixtures, test-only repairs and browser scenarios. | Depends on the direct bridge and its shared controls. Verify refusals, rollback, callback wiring and original versus repaired acceptance. Keep source corrections confined to explicit test candidates. |
| Validation and release packaging | `.github/workflows/webui_tests.yaml`; `spec/webui/package*.json`; browser/support harnesses; native-helper build/distribution material and documentation. | Validation must accompany each applicable package, not wait for the last PR. Host binaries/signing need a separate release decision; test-only Node dependencies are not runtime requirements. |

Some rows may be combined into one PR, or split further after measuring the
actual upstream diff. That decision belongs to the owner/EO review discussion.
The existing generic contract should not be repeatedly extended to replay our
development chronology when a coherent final capability can be reviewed once.

### Builder removal boundary

Core WebUI and native consumers do not depend on Builder. Delivering without it
is architecturally possible, but **reverting PRs #34–#38 wholesale is not a safe
removal recipe**: those PRs also repaired shared controls, adapter behavior and
the renderer used by native pages and direct GTK calls. Omit the Builder loader,
its integration and dedicated acceptance material deliberately; retain generic
behavior and its non-Builder tests. No such removal or extraction was performed
as part of this documentation update.

### Required extraction manifest before publication

For each adopted PR, record the exact EO base SHA, predecessor merge requirement,
source file/hunk inventory, matching documentation and tests, and validation of
that intermediate checkout. Compare the base first so already merged EO work is
not duplicated. Review mixed files such as `lib/webui.rb`, `tree_builder.rb`,
`app.js`, `app.css`, `script.rb`, startup and gem selection at the hunk level.
Historical development commit IDs are provenance, not a substitute for this
manifest. Creating that manifest and proving intermediate states are outstanding
work; this source map does not claim they have been completed.

## Validation record

The documentation reconciliation on 2026-10-11 reran the full suite against the
PR #38 code baseline using Ruby 4.0.5 and RSpec seed `50188`:
**9,022 examples, zero failures, 16 browser-only pending**. RuboCop inspected
**1,306 files with no offenses**. These are dated results, not permanent
suite-size guarantees.

Earlier implementation evidence remains separate: the internal-combo refusal
regressions failed before the fix and passed afterward. A scheduling probe reproduced the
Bigshot race, passed with the bounded wait, and failed on timeout when the final
callback was deliberately withheld.

The separate Chrome selection contains 16 cases at this baseline. Its enabled
command and the renderer command are in the test guide. Pending cases in ordinary
RSpec are not successful Chrome executions. This documentation update does not
relabel earlier browser evidence as a fresh run, claim current remote CI status,
or certify native OS-window behavior. Record run URL/SHA and platform with the
acceptance evidence for each eventual EO PR.

## Documentation reconciliation inventory

This pass changed only the following documentation. Behavior claims were checked
against implementation and test coverage; historical provenance was retained as
history rather than presented as current instructions. Local links, anchors and
code fences were checked, and `git diff --check` passed. External release assets
and current upstream proposal status were not revalidated.

| File | Reconciliation |
| --- | --- |
| [README.md](../README.md) | Identify this development tree and its WebUI architecture; distinguish upstream release links. |
| [GTK-HARDENING.md](GTK-HARDENING.md) | Replace retired native GTK loop/shutdown instructions with current shim ownership and cleanup behavior. |
| [macos-bundler-recovery.md](macos-bundler-recovery.md) | Correct startup dependency groups and legacy flag semantics. |
| [r4l5-gem-recovery-manifest.md](r4l5-gem-recovery-manifest.md) | Distinguish platform recovery paths and historical GTK payload examples from current requirements. |
| [saved-frontend-editing.md](saved-frontend-editing.md) | Describe the implemented WebUI forms, availability checks and edit-duplicate limitation; remove obsolete GTK test instructions. |
| [webui-integration.md](webui-integration.md) | Reconcile current contract, Builder/control boundaries, queue failures, bounded CSS and validation claims. |
| [spec/README.md](../spec/README.md) | Reconcile test isolation, callback completion and browser versus Ruby evidence; remove contradictory reset guidance. |
| [fixture README](../spec/fixtures/webui/README.txt) | Clarify frozen sources, original versus repaired acceptance, and repository listing coverage. |
| [This handoff](webui-review-readiness.md) | Record merged work, remaining gaps, evidence boundaries and proposed EO review packages. |

## Keeping the handoff current

An implementation change must update the behavior guide, affected fixture/test
claims and relevant status/dependency rows together. A completed development PR
does not automatically close a source-author or platform gap. Preserve historical
provenance as dated history, replace obsolete user instructions, and identify
missing evidence explicitly instead of marking it complete. Do not alter the
owner's PR descriptions as part of documentation maintenance.
