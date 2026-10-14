# Engineering brief: explicit GTK CSS decoration fallback

PR 4 merged as [PR #55](https://github.com/Lich5/lich-6/pull/55) on 2026-10-14
at `bfd4f3fd`, including final reviewed head `03115933` and passing CI.
The implementation adds script-owned GLib Timeout/Idle/Source facades on one
core timing worker and the existing owner dispatcher. Contract 2.21.0 includes
inherited layout sensitivity and retained window hide/show. Repository v2.76
acceptance retains the real ten-second timer. Sail2's original startup race
remains a negative case; the separately labeled test-only repair permits
setup/save/close acceptance. CENTER/set_position aliases and gemstonev's unchanged
difficulty-window/timer flow are covered, with the existing placement fallback.
Lifecycle notifications remain accepted through disabled/hidden controls.
No native GTK or script/game logic changes are included. Implementation slices
1–4 are merged; source acceptance refresh remains proposed and optional tpick
image windows remain deferred. Earlier handoff entries below are historical.

Scope decision, 2026-10-13: `map` is already converted to
native WebUI; its predecessor `xnarost` receives no compatibility expansion and
retains the standard unsupported-operation/migrate-to-WebUI message. `sea-charts`
is a proposed native conversion, not a shim pointer/layout project. Priorities
consider script lineage, EO ownership, usage/downloads and community activity
alongside header dates; popularity has not been measured in this assessment.

PR 3, merged as [PR #54](https://github.com/Lich5/lich-6/pull/54) on 2026-10-14:
shared host-owned, best-effort monitor geometry for
`manatimer`/`gemstonev`, plus generic named cursor hints for
`gemstonev`/`highlight-manager`. Placement remains a host request, with explicit
fallbacks; exact multi-monitor placement is not an acceptance requirement.
Cursor names describe appearance only, with a browser-default fallback. No
pointer polling, device emulation, Gtk::Layout expansion or script-specific
behavior is included. The [bounded proposal and acceptance scope](webui-review-readiness.md#pr-3-proposal-geometry-and-named-cursors)
records the approved scope, validation and remaining native-platform limitations.
The owner explicitly approved the bounded geometry and named-cursor shared-core
extensions. Branch `feat/webui-monitor-geometry-cursors` started from synchronized
main at `585bb871`, preserving the prior documentation edits. Contract 2.20.0 adds
monitor hints and named cursor presentation. After the owner's merge, `main` and
`origin/main` were synchronized at `5f2d0e86c759572d424da2ed3093b22c2db998f3`,
with zero divergence. PR 4 scheduling implementation is recorded above;
optional tpick image windows remain deferred. No assistant
staging, commit or push was performed.

Merged follow-on history (2026-10-12): CSS fallback PRs #41 and #42,
HeaderBar/default tpick setup PR #43, and generic progress/overlay PR #48 are merged.
`main` / `origin/main` were synchronized at `d7726455642267a4b97f425492e995dcd68ea2ad`.
The owner approved bounded overlay pass-through and progress pointer-event
extensions (contract 2.19.0). Text visibility, alignment and decoration toggles
are included; monitor geometry, CSS expansion and full manatimer setup are not.
The owner also approved consistent core progress rendering: requested dimensions
apply independently of CSS recognition, and recognized colors only override fill.
This changes no CSS grammar and introduces no script-specific rendering branch.
The owner expanded the HeaderBar PR to signed Grid origins and default tpick setup,
including generic class-qualified label foreground cues. Explicitly approved shared
extensions are atomic `Adapter#layout_grid` and empty notebooks (contract 2.18.0).
Optional image windows remain a separate follow-up by owner decision. The
[current tracker](webui-review-readiness.md#refreshed-gtk-compatibility-work-tracker)
records acceptance and source limitations. These decisions supersede the older
exclusions only for those bounded surfaces; the brief below remains provenance.

Date: 2026-10-11. Updated 2026-10-12: **CSS fallback PRs [#41](https://github.com/Lich5/lich-6/pull/41) and [#42](https://github.com/Lich5/lich-6/pull/42) are merged**.
The owner approved the two-PR sequence in the
[current tracker](webui-review-readiness.md#css-decoration-work-tracker).
PR 1 added progress-provider lifecycle support. PR 2's first local slice adds
explicit provider states, inert omission with an attributed notice, and reset of
previous progress effects. The second local slice adds shared widget contexts,
bounded class metadata, owner-scoped screen providers and dimension-only geometry
notices. The final local slice records [corpus measurements and source-derived
acceptance](webui-css-decoration-acceptance.md), with whole-setup limits and
independent hard stops kept explicit.
The original handoff and evidence below remain dated provenance.

PR #41 merged at `2026-10-12T07:35:31Z` as
`de8765199cdea6e73ed19cd5a9b6fcab759abea6`, including the destruction-race fix.
Local `main` was fast-forwarded to that commit and verified equal to `origin/main`.
PR 2 started on `feat/webui-css-decoration-fallback` from that synchronized base,
preserving the uncommitted post-merge documentation updates. Provider state and
recognized-to-omitted reload/reset work uses the existing owner monitor. The
8,192-character bound remains unchanged: all 71 retained literals/samples from
the 33 cached scripts fit, with a measured maximum of 6,230. Dynamic strings and
settings are not proven universally bounded by those samples.

PR 1 started from synchronized `main` at
`c2f4a2a2f0cee4ab01aa53e91886423143afb884` on
`feat/webui-progress-provider-lifecycle`. The owner explicitly approved a narrow
shared-core extension: `Adapter#set(handle, property, Adapter::UNSET)` removes an
optional shared property and revalidates the result without replacing its handle.
This restores absent progress fill/height without inventing theme values. No
renderer or component-schema expansion is required.

## Assignment and controlling decision

The owner's implementation authorization was:

> Approved. Implement the explicit decoration fallback, preserve the existing
> progress styling, document the omissions, and test against tpick and the other
> CSS scripts. Unsupported widgets and behavior should still hard stop.

At the original handoff, the owner interrupted the turn to request this engineering brief. Only an
implementation handshake had been sent; no fallback code or tests were changed.
The receiving session should carry out the approved work, not repeat the decision
discussion or begin the earlier, substantially larger CSS translation proposal.

The approved approach deliberately permits omitted CSS decoration while rendering
supported controls using the existing WebUI theme. Keep values, contents,
callbacks, supported layout requests and existing behavior intact. This is an
explicit exception to original-GTK visual matching, not permission to conceal
missing widgets, broken script logic or unsupported interactions.

## Workspace, branch and policy handoff

- Implementation repository: `/Users/doug/dev/Projects/lich-6`.
- Governing policy: `/Users/doug/dev/Projects/AGENTS.md`; read it and any applicable
  nested policy at initialization. No nested policy was found during this audit.
- At handoff, branch `docs/webui-review-readiness` is at
  `1cfd584017a7a990c89692c9ac3981f211714d2d`, the owner's documentation commit.
- Local `main` and the last-fetched `origin/main` both point to
  `d3e41e71eb335acb80cdd599a3038026d5df5134` (PR #38). Remote state was not refreshed
  for this brief. The documentation commit contains no product changes.
- The working tree was clean before creating this brief and its evidence file.
  Preserve these files and any later owner changes during transition.
- Implementation branches start from synchronized `main`, never from a stack of
  unmerged feature branches. If documentation must merge first, coordinate that
  dependency with the owner. Do not lose the handoff while switching branches.
  A suggested implementation branch is `feat/webui-css-decoration-fallback`;
  branch names must not contain `codex`.
- Staging, commits and pushes are human-only. State:
  `Git boundary: human-only staging, commits, and pushes; assistant will not ask.`
- For Ruby work initialize a host interactive zsh, verify `rubystd`, execute it,
  verify Ruby 4.0.5, and restore the intended cwd: `rubystd` changes it to lich-5.
  Reuse that initialized session. Do not use sandbox/system Ruby or install gems.

The owner explicitly authorized inspection of these source repositories:

| Repository | Source used in the audit |
| --- | --- |
| `/Users/doug/dev/Projects/scripts` | EO originals from Git revision `7fd0b971387492cfd81b4bc7ef94428413965071`; native conversion candidates from the locally modified working tree |
| `/Users/doug/dev/Projects/lich_repo_mirror` | Local mirror revision `549e33506e121453e3c01cfe5df46a902f44fc5f`; principally `lib/`, with DR duplicate checking |

The initially supplied `Projects/mirror-scripts` path was corrected by the owner
to `Projects/lich_repo_mirror`. The EO scripts checkout has many local changes;
do not treat its working files as unchanged GTK originals or overwrite them.
The source baselines above were not fetched to establish latest upstream status.
Cross-repository source changes are not part of this assignment.

## Why this work is needed

At the original audit, `CssProvider#load` in
[`style.rb`](../lib/common/script_scope/gtk/style.rb) accepts only an exact
progress-stylesheet grammar originally measured from `spellson`. It extracts
an allowed fill color. `StyleContext#add_provider` applies that color and a
24-pixel progress height at `PRIORITY_USER`.

This was not a general CSS parser. Even `staminabar2`'s almost identical stylesheet
failed because its final color declaration lacked a trailing semicolon. An isolated
diagnostic string with that semicolon added passes; the source script was not
edited. PR #41 subsequently accepted that missing final semicolon. Preserve
existing accepted progress rendering, but do not turn this task
into a collection of script-specific regex exceptions.

For mirror `tpick.lic` version 48:

- Original provider setup begins at line 94; the actual shim refusal is
  `CssProvider operation=load source=tpick.lic:95`.
- Its main literal is 4,742 characters, below the current 8,192-character limit:
  28 rules, 80 selectors, 17 distinct property names.
- It uses global provider registration at line 291, a label-local stylesheet at
  line 2558 and a `required-setting` class at line 2939.
- Existing code has no `StyleContext.add_provider_for_screen`, general widget
  `style_context`, or `StyleContext#add_class`. A load-only no-op will therefore
  not solve the call chain.
- `Gtk::HeaderBar` is also absent. That is a separate widget gap and **must remain
  a hard stop**. Do not add HeaderBar, fabricate it, or claim complete tpick UI
  acceptance as part of making its decoration calls nonfatal.

All line numbers refer to the audited sources; verify hashes before reusing them.

## Approved surface and implementation guidance

The following dispositions were discussed and approved. Exact implementation
details are engineering work, subject to the existing architectural boundaries.

| Operation | Intended disposition |
| --- | --- |
| `CssProvider#load(data:)` and `#load_from_data` | Recognize the existing supported progress case; otherwise accept bounded stylesheet input as omitted decoration and report that omission. Never forward source CSS to the browser. |
| Per-widget provider attachment/removal | Supply an explicit style facade on supported widgets. Accept supported call shapes; omitted decoration leaves the normal WebUI appearance. Do not write progress-only properties onto labels or other controls. |
| Screen-level provider attachment/removal | Supply the observed API surface as owner-scoped compatibility bookkeeping/omission. It must not affect other scripts, native pages or process-global appearance. |
| Style-class addition/removal | Retain owner/widget-local membership for supported queries such as `has_class?` and `list_classes`; do not interpret classes as DOM identity or apply arbitrary styling. |
| Existing accepted progress stylesheet | Preserve the current fill color, height and lack of style leakage into sibling labels. |
| Unsupported widget, behavior or unrelated method | Keep the existing explicit refusal. No generic `method_missing` forgiveness, placeholder widget, nil suppression or blanket callback rescue. |

Important details discovered in the corpus:

- Callers use both USER and APPLICATION provider priorities. Some attach a
  provider before loading it, omit an attachment priority, or later reload the
  same provider. Inspect actual call forms before selecting signatures.
- `manatimer` attaches before load; `stormsync` attaches without an explicit
  priority and removes/reloads providers. `panelcontrol` changes appearance live.
  Support the decoration lifecycle deliberately rather than moving the failure
  from `load` to the next call.
- Account for multiple attachments and removal. If a previously applied supported
  progress provider is removed or reloaded as omitted decoration, define and test
  how its prior effects are cleared without overwriting unrelated script values.
- Keep existing input-type and size bounds unless a measured need justifies an
  explicitly reviewed change. Invalid objects or call shapes are not decoration.
- Keep bookkeeping bounded and tied to session/widget cleanup. Do not introduce
  another service, dispatcher, event loop or persistent global style registry.
- Use the existing degradation mechanism where practical: consolidated notice
  once per script/session, with useful operation and source attribution. Avoid
  printing entire stylesheets or settings. Additional diagnostic detail must
  remain distinguishable from implemented styling.
- CSS URLs, imports and functions must never execute or trigger file/network
  access. Omitted strings are inert. A fallback is not an arbitrary-CSS channel.
- Do not expand direct `Gdk::RGBA`, `override_color`, Pango markup, native chrome
  or unsupported widget APIs simply because they also affect appearance. Record
  those separately if testing reaches them.

The earlier full-translator proposal included selector matching, cascade,
state-dependent core styling and new typed presentation properties. **That is
not this task.** Its five-to-eight-day estimate does not apply to this fallback.
No separate user-facing opt-in mode or settings UI was requested by the final
implementation approval.

Likely implementation locations are `gtk/style.rb`, the shared Widget surface
in `gtk/widgets.rb`, the current progress facade in `gtk/displays.rb`, and session
cleanup/diagnostics only where necessary. Start with shim-owned changes. Shared
core changes require a demonstrated need; default core controls already render.

## Corpus evidence and counts

The companion [audit evidence](webui-css-decoration-audit.json) retains cohort
membership, source hashes, source locations, parser findings and probe results.
It combines the focused audit with the later whole-corpus provider count. It
does not contain all source text; originals remain available from the named
repositories/revisions. The brief must remain useful without `/private/tmp`.

### Established groups

| Group | Members and result |
| --- | --- |
| 13 Builder scripts | `BlackArts`, `bigshot`, `ebounty`, `ecleanse`, `eherbs`, `eloot`, `ewaggle`, `go2`, `repository`, `huntplan`, `slootbeta`, `stormsync`, `bigshit2`. Only `stormsync` has stylesheet-provider demand. Its exclusion from further Builder expansion remains in force. |
| 15 converted candidates | `BlackArts`, `bardwag`, `bigshot`, `calibrate_creaturebar`, `creaturebar`, `ebounty`, `ecleanse`, `eherbs`, `eloot`, `ewaggle`, `go2`, `jinx`, `map`, `repository`, `soundfx`. Only the original creaturebar/calibrator pair uses CSS providers; none of these native candidates does. |
| 12 random non-overlapping GTK scripts | `osacrewv2`, `sloot`, `song-manager`, `panelcontrol`, `Live_Market`, `old-service-cost`, `gemguard`, `osacrew_avalon_wizard`, `armor`, `fletching`, `isigils`, `loot-be-gone`. `panelcontrol` uses CSS; old-service-cost and osacrew_avalon_wizard have separate direct-color API gaps. |
| Eight additional CSS examples | `spellson`, `staminabar2`, `timers`, `manatimer`, `grids`, `as_audit`, `grinsawl`, `Combatical`. These test progress variants, text, lifecycle, class changes, drag/drop decoration and broader stylesheets. |
| Focal case | `tpick`, in addition to the groups above. |

The random sample was selected from 198 GTK source candidates, excluding the
established groups and tpick. Sort by SHA-256 of
`2026-10-11-css-audit:<basename>` and take the first twelve. EO Git originals take
precedence over mirror copies of the same basename. This is a GTK-focused sample,
not a random sample of all game scripts.

The focused set contains 40 distinct originals plus 15 native candidates. All 55
parsed successfully with Ruby Prism. This establishes source analysis, not full
GUI, gameplay or visual acceptance. CSS absence does not imply absence of Pango
markup or other unsupported methods. `bsprofiles` dynamically reuses Bigshot's
Setup; it was not counted as another independent Builder definition.

### Whole-corpus CSS-provider exposure

There are **33 distinct original script names** with actual CssProvider references:

`Combatical`, `UberBarWiz`, `as_audit`, `bug-catcher`, `calibrate_creaturebar`,
`creaturebar`, `creaturewindow`, `exitwindow`, `gemstone-tracker`, `gemstonev`,
`generate-gemstone`, `grids`, `grinsawl`, `gshunting4all`, `hazardwindow`, `jastev`,
`manatimer`, `manatimer-gtk3`, `merchantical`, `mission-gemstone`, `nautical-charts`,
`panelcontrol`, `playerwindow`, `rafflewindow`, `spellson`, `staminabar2`,
`stormsync`, `test-tpick`, `thunder`, `timers`, `tpick`, `tpick2`, `treasurewindow`.

Subtract the two existing native conversions and spellson's existing supported
styling: **30 remaining scripts need disposition for unsupported CSS**. The
earlier 32-file count included identical GS/DR stormsync copies; it represented
31 distinct names in the current working files, not 32 independent scripts.
Separately named variants are counted separately, not as distinct user populations.

Thirty is an exposure count, not thirty proven fatal failures or mandatory native
conversions. `grinsawl` and `gshunting4all` rescue their CSS decoration paths and
continue. `merchantical` rescues provider loading but also calls style classes
elsewhere, so that rescue alone does not prove it can continue. Script authors
could remove decoration instead of converting their entire interface. Non-CSS
failures are outside this provider count. The broad count is backed by syntax-tree
references, not only text matches; all 33 originals parsed successfully.

## What to test

Use isolated actual source excerpts or safe harnesses. Do not execute whole game
loops, external downloads, settings writes or live-game actions just to test CSS.
Retain source provenance and label any diagnostic substitutions. No repairs to
production script sources belong in the shim.

1. **Preserved progress:** existing spellson regression; color and height remain
   unchanged and sibling labels remain unaffected. Fraction updates still work.
2. **Fallback lifecycle:** actual tpick global and label-local CSS; per-widget and
   screen attachment; USER/APPLICATION/default call forms; attachment before load;
   repeated loads, removals and multiple attachments; class add/remove/query.
3. **No styling side effects:** fallback leaves supported controls' values,
   contents, callbacks, typed layout and default rendering intact. No source CSS
   enters the protocol, DOM or stylesheet. No URL/import is accessed.
4. **Owner isolation and cleanup:** two scripts may use identical names/classes;
   neither can affect the other's widgets, reports or provider state. Destroy and
   owner death release retained style objects. Test relevant viewer isolation.
5. **Hard-stop preservation:** tpick still refuses HeaderBar; unknown widget/API,
   invalid Builder reference and unsupported behavior still fail. Keep eloot and
   Bigshot original-source negative acceptance intact.
6. **Corpus contrasts:** small progress variants; timers/manatimer live providers;
   as_audit typography; panelcontrol states; grinsawl optional borders;
   Combatical drag/drop classes; grids images/gradients as inert omitted data.
   Use stormsync's CSS call shapes without reopening its excluded feature scope.
7. **Acceptance accounting:** record original script/source, CSS result, next
   non-CSS blocker, omission notices and whether a whole setup actually rendered.
   Never equate a passing provider call with a working whole script.
8. **Documentation and checks:** update implementation comments, the integration
   guide, test/fixture guidance and current handoff status together. Run focused
   regression coverage, full RSpec and RuboCop in the required host environment.
   Run renderer/browser checks if their behavior changes or visual acceptance
   requires them; ordinary browser-pending RSpec cases are not Chrome execution.

Visual review must call out lost required-field colors, selection borders and
drag/drop indicators. Do not describe those omissions as necessarily harmless.
The intended default appearance is still useful, but its limits must be visible.

## Existing evidence, not future acceptance

- Current tpick source excerpt reproduced `UnsupportedOperation` at line 95.
- Its separate label stylesheet also refused. The missing APIs and HeaderBar
  class were confirmed against the shim.
- Spellson's stylesheet with an observed palette color passed the actual loader.
- Staminabar2's original literal refused; a diagnostic trailing-semicolon
  normalization passed. No source modification was made.
- Stormsync's selection-border literal refused; OSA's gray RGBA parse refused
  separately. The latter is not a CSS-provider defect.
- Focused regression: `rspec spec/lib/common/script_scope_widgets_spec.rb
  --example 'preserves spellson colors' --format progress` passed, one example,
  seed 58377.
- Previous documentation-pass full suite at the PR #38 code baseline: 9,022
  examples, zero failures, 16 browser-only pending, seed 50188; RuboCop inspected
  1,306 files without offenses. These are historical baselines, not validation
  of the not-yet-written fallback.

## EO proposal comparison and architectural guardrails

The labeled EO PRs were checked on 2026-10-11: closed and unmerged, ending at
`b56457a6ab782d47be33d15d28ee9acc55e01c18`. In particular:

- [PR #1653](https://github.com/elanthia-online/lich-5/pull/1653) used broad
  degradation: unknown methods logged and returned self/nil; unknown widget
  classes became empty containers; a per-script ledger reported omissions.
- [PR #1654](https://github.com/elanthia-online/lich-5/pull/1654) skipped unknown
  Builder material and reduced unsupported rich-text presentation.
- Their final shim did not implement a complete CssProvider/StyleContext call
  chain. Generic stubs are not evidence of successful tpick acceptance.
- Their ledger/reporting is useful design evidence. Their placeholder-widget,
  generic nil-return and broad suppression behavior conflicts with this task's
  hard-stop boundary. Do not copy it into this implementation.

EO/unmerged and converted implementations are references, not architecture
authority. Reuse generic mechanisms where they fit. Do not introduce script-name,
widget-ID or business-rule special cases. The shim remains a migration bridge.

## Completion expected from the fresh session

Deliver local implementation, focused source-derived regressions, documented
omissions, validation results and an exact changed-file/status report. Report
separately which CSS call chains now continue and which scripts still stop for
non-CSS reasons. Do not create a claim of full tpick support by suppressing its
next failure. Do not stage, commit or push.

Alias ownership repair, saved-character duplicate handling, author repairs for
eloot/Bigshot, platform packaging and EO PR extraction remain separate work.
See the [general handoff](webui-review-readiness.md) for that broader context.
