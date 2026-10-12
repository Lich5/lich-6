# WebUI review readiness and handoff

Reviewed baseline: 2026-10-11, `main` at `d3e41e71eb335acb80cdd599a3038026d5df5134`
(PR #38 merged). This record describes the development tree, not an EO release.
The documentation reconciliation branch is `docs/webui-review-readiness`.
Update the baseline and affected status rows when subsequent work is adopted.

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
The script-local GTK shim translates a bounded surface through the ten-operation
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

PR #38 includes the bounded wait for Bigshot's nested profile callbacks and the
refusal of both character-limit setters on internal combo entries. Neither is
outstanding. The latter preserves existing text and emits no change signal;
standalone Entry limits remain supported. The host/browser contract is 2.17.0.

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
| 1. Progress provider lifecycle and compatibility | `CssProvider#load` and positional `load_from_data`; optional final semicolon in the bounded progress grammar; `ProgressBar` provider references, attach-before-load, reload and removal; APPLICATION/USER priorities and attachment-order ties; restoration of authored/default fill and height; owner synchronization, isolation and cleanup. Focused spellson/staminabar2 and lifecycle regressions. Explicitly approved adapter `UNSET` reset for optional shared properties. | **Ready for owner review**: local working-tree implementation on `feat/webui-progress-provider-lifecycle`, based on `main` at `c2f4a2a2f0cee4ab01aa53e91886423143afb884`. Not staged, committed, pushed or confirmed merged. |
| 2. Explicit CSS decoration fallback and acceptance | Unloaded/recognized/omitted providers; shared `Widget#style_context`; widget and owner-scoped screen provider attachment/removal; class add/remove/query; observed call forms; consolidated attributed omission notices; Screen geometry notice correction; CSS size measurements and cached-corpus acceptance accounting. Preserve unsupported-widget/behavior hard stops, including HeaderBar. | **Not started**; starts after owner confirms PR 1 merged. |

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
character input limit remains unchanged pending that slice's measurements.

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

### Other open work

| Item | Status / next decision |
| --- | --- |
| Alias detached-thread ownership repair | Approved as separate work after PR #38; not implemented in this branch. Preserve the owner requirement and address the script's ownership/lifetime. |
| Saved-character edit duplicates | Documentation audit found that `Catalog#update_character` does not perform the duplicate-destination check used by `add_character`. The guide now states the limitation. No behavior change adopted or implemented in this documentation pass. |
| eloot and Bigshot author repairs | Await source updates; retain original negative tests and separately labeled corrected candidates. |
| Windows/Linux native-window acceptance | Still open for actual focus, topmost/opacity where supported, geometry and process cleanup; Linux Chrome transport tests do not certify these. |
| macOS distribution | Signed/notarized helper packaging, older supported macOS and physical Intel acceptance remain release work. Local helper builds are not distribution certification. |
| Arbitrary GTK CSS and internal combo-entry character limits | Arbitrary CSS still refuses in PR 1; explicit decoration omission is approved for PR 2 above. Full CSS translation and combo-entry character-limit expansion remain excluded. |
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
