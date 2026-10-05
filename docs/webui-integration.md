# WebUI integration onto proposed 5.22

Updated October 5, 2026. This replaces the initial preparation notes in the
separate `lich-6-webui-5.22` worktree. Work takes place in the normal `lich-6`
checkout. Proposed 5.22 is a snapshot, not a released upstream tag.

## Baseline and sequence

- Active checkout: `/Users/doug/dev/Projects/lich-6`.
- EO main incorporated: `58ffd5f19b609df0a22c9060f8ad72781a2bc559`.
- Local and origin main aligned by the owner:
  `b95e324823a2db71af72329236d556a47b28e4df`.
- The only baseline difference from that EO snapshot is `lib/version.rb`:
  `LICH_VERSION = '5.22.0'` instead of `5.21.0`.
- Current feature branch: `webui/01-foundation-shim`, based on `b95e3248`.
- The three old 5.21 WebUI PRs, #7, #8 and #9, are closed and unmerged.

| Slice | Scope | Branch | Publication |
| --- | --- | --- | --- |
| 1 | Existing WebUI foundation, browser host, renderer and bounded shim; selected correctness fixes | `webui/01-foundation-shim` | Working-tree changes only |
| 2 | Native launcher, login/settings/Frontends, authentication integration, startup/script activation and GTK runtime removal | `webui/02-native-cutover` | Not started |
| 3 | Functional preference-driven dark mode; `setup_footer`, `text_list_spec`, `choice_options` | `webui/03-theme-helpers` | Not started |

After slice 2, exercise actual launcher/login, map and uberbar_eo, including
close/reopen and cleanup. After slice 3, finish practical acceptance of all 15
script conversions. **Beta requires all three slices and all 15 conversions.**
Script logic, including existing quirks, must remain unchanged.

Review new EO main commits at each day's start and incorporate relevant changes
deliberately. Record the new incorporated SHA and run affected checks. A fetch
alone does not update this implementation. No daily automation is configured.

## Preservation and PR 1 contents

The preserved source is `test/integration` at
`14c5d16bbbcc60693686620a223d556035cb0650`, together with its then-uncommitted
40 modified tracked files and 36 untracked files. The original checkout is no
longer on that branch. Recovery remains available through its local refs,
the owner's stash, and `backup/webui-before-5.22-2026-10-05/` (Git bundle,
patches, copied working files and full source SHA-256 manifest).

PR 1 imports 86 files from that preserved state, with every imported source
hash checked before writing. It adds the existing contract 2.9.0, 29 component
types and ten-operation imperative adapter, renderer, loopback service,
browser ownership/geometry, forms and bounded script-local GTK compatibility.
The shim population and public component types are not expanded.

No pre-existing 5.22 tracked file is modified. In particular, `lich.rbw`,
`lib/common/script.rb`, the main/async/frontend paths, dependency files and
release configuration retain the baseline. Normal startup is still GTK in this
slice. The WebUI API can be explicitly required for testing; activation in the
normal application belongs to slice 2. Core WebUI has no dependency on the shim
or the GTK gem. No script conversion or installed script was changed.

Corrections made after import, each demonstrated by a failing-before regression:

| Production file | Correction |
| --- | --- |
| `lib/webui/dispatcher.rb` | Refuse callbacks after owner termination; coalesce only within the same viewer; report callback class and source location without exception values |
| `lib/webui/runtime.rb` | Pass the logger to its default dispatcher; capture detach lifecycle contexts before a close callback can clear the attachment |
| `lib/webui/service.rb` | Use Lich's logger by default when available |
| `lib/webui/server.rb` | Port-specific authentication cookies; bounded nonblocking WebSocket writes, including waiting for the writer mutex |
| `lib/webui/modal_coordinator.rb` | Resolve a modal on user close; remove a registration when opening fails before completion cleanup is installed |

These are changes to the imported core foundation, not script-specific
workarounds. Eleven added regression examples cover them, including identity-based
termination for distinct-but-equal owners and support for symbol owners. The imported shim test
also now permits real GTK already loaded by 5.22's tests while verifying that
the script-local shim neither creates nor replaces GTK constants in core.
Additional import-only lint cleanup consists of alignment/blank lines in the
contract and specs, unused test arguments, ASCII source notation for two Unicode
test values, and a documented lint exception for HostThread's cleanup-and-reraise
on interruption. These do not change runtime behavior.

## Upstream proposal disposition

The twelve EO PRs labeled `webui` were closed and unmerged at assessment.
They are reference proposals, not a second stack to import wholesale.

| Proposal | Disposition |
| --- | --- |
| #1634, #1649, #1655 | Earlier vendor/dual-launcher/default-WebUI approaches are superseded by this three-slice plan; GTK removal belongs to slice 2 |
| #1648 | Selected owner termination, viewer coalescing, cookie isolation, WebSocket deadline and modal cleanup corrections are included; stale-event ordering, bounded shutdown, listener recovery and rendering outside the adapter lock already exist in the preserved source |
| #1650 | Preserve the existing bounded contract instead of importing its broader revision; retained renderer already has bounded stale-event retry |
| #1651, #1652 | Reconcile authentication, saved-entry identity, frontend and cancellation changes during native cutover |
| #1653, #1654 | Do not replace the existing script-local bounded shim with the alternative broader implementation/session worker |
| #1657 | Logger delivery and close/detach race corrected here; launcher password/favorite handling belongs to slice 2; window-discovery changes target a different host implementation |
| #1658, #1659 | YARD expansion and chips/contract expansion are not included |

Other #1648 proposals have not been adopted: queue/reverse-map performance
changes, a maximum served-file size, timed cancellation after a transient modal
disconnect, and Windows presentation/adoption changes. Revisit relevant lifecycle
cases during slice 2's actual launcher integration; do not represent PR 1 as the
whole of #1648 or all platform acceptance. A modal user-close now cancels it;
a transport loss alone retains the existing reconnect/timeout/owner-termination
behavior. No new reconnect grace policy is introduced in this slice.

## Validation and limits

Validation results are recorded below. Browser-content checks
are distinct from OS-window geometry, restoration, independent-window cleanup,
GTK visual comparisons and live game acceptance. Those later acceptance steps
are not closed by these tests.

- Final focused foundation/shim suite: 276 examples, zero failures, two
  browser-gated cases (seed 62369).
- Both gated cases separately passed in actual headless Google Chrome:
  checkbox and entry values/activation, separator rendering, callback delivery;
  two examples, zero failures, no browser page errors. No visible blank tabs.
- Dependency-free renderer checks: 76 passed, including a rerun after relocating
  all 14 renderer tests/fixtures to `spec/webui/`. Their contents are unchanged;
  the same directory depth preserves existing relative asset paths. The empty
  top-level test directory was removed.
- Older `webui_renderer_test.cjs` could not run because `jsdom` is absent from
  this host's module paths. No dependencies were installed.
- RuboCop: all 69 added Ruby files inspected, no offenses.
- Ruby compilation and whitespace checks: all added Ruby files compile; all
  87 additions pass whitespace checks. No baseline file or index changes.
- Final full 5.22 suite: **8,750 examples, zero failures, two browser-gated
  cases**, seed 63710, Ruby 4.0.5. Both gated cases passed separately above.

The first full run found only the shim test's assumption that global GTK was
absent (8,748 examples, one failure, two gated cases). That assumption conflicts
with this staged integration; the corrected test checks namespace preservation.
A first browser harness run used the wrong `hr` selector for the existing
`div.webui-divider`; correcting the disposable harness yielded the passing
browser run above. Neither issue required a product rendering change.

## Publishing the same feature for EO review

Proposed PR title: **Add WebUI foundation and bounded script compatibility**.

Proposed description: Add the preserved WebUI renderer, authenticated loopback
service, native browser host, forms and script-local compatibility layer onto
the proposed 5.22 baseline. Correct callback ownership, viewer coalescing,
multi-session authentication, write deadlines and modal lifecycle issues with
focused regressions. Normal startup remains unchanged until the subsequent
native cutover PR. Validation and remaining platform/browser limits are recorded
in this document.

Git staging, commits and pushes are human-only. No new PR has been created.
This feature's implementation base is the full `b95e3248` SHA above; there is no
reviewed feature commit/head SHA yet because these are uncommitted changes.

`Lich5/lich-6` shares history with EO but is **not registered as a GitHub fork**.
Do not assume GitHub will accept a cross-repository PR from it. The owner has
EO write access, so a matching feature branch in EO (or a true GitHub fork) is
the publication route. The local upstream push URL remains disabled.

For each owner-published slice, record its Lich5 PR URL, EO PR URL, implementation
base, feature commit list and reviewed head. Replay only those feature commits
onto the recorded EO baseline plus any predecessor slices. Do not include the
fork's version bump or future daily synchronization commits in the feature PR.
Compare the resulting feature diff; rebasing/squashing may change commit IDs.
While an EO predecessor is unmerged, retain an explicit dependency or target its
review branch. Record and retest any adjustment required by newer EO code.

No staging, commits, pushes, script installation or release actions were
performed by the assistant. Scope used: lich-6 implementation, its preserved
source and the earlier authorized integration-plan reference. No changes were
made to EO's reference checkout or to unrelated working trees.

## Exact added files

The list below includes this integration record. All are new relative to the
PR base; there are no modified or deleted baseline files.

- `docs/webui-integration.md`
- `lib/api/webui.rb`
- `lib/common/script_scope.rb`
- `lib/common/script_scope/gtk/boot.rb`
- `lib/common/script_scope/gtk/dialogs.rb`
- `lib/common/script_scope/gtk/displays.rb`
- `lib/common/script_scope/gtk/inputs.rb`
- `lib/common/script_scope/gtk/layout.rb`
- `lib/common/script_scope/gtk/session.rb`
- `lib/common/script_scope/gtk/style.rb`
- `lib/common/script_scope/gtk/widgets.rb`
- `lib/webui.rb`
- `lib/webui/adapter.rb`
- `lib/webui/assets/app.css`
- `lib/webui/assets/app.js`
- `lib/webui/assets/index.html`
- `lib/webui/browser_launcher.rb`
- `lib/webui/browser_window.rb`
- `lib/webui/component.rb`
- `lib/webui/contract.rb`
- `lib/webui/dispatcher.rb`
- `lib/webui/errors.rb`
- `lib/webui/file_service.rb`
- `lib/webui/future.rb`
- `lib/webui/host_thread.rb`
- `lib/webui/image_size.rb`
- `lib/webui/list_settings_form.rb`
- `lib/webui/modal_coordinator.rb`
- `lib/webui/page.rb`
- `lib/webui/protocol.rb`
- `lib/webui/registry.rb`
- `lib/webui/runtime.rb`
- `lib/webui/sensitive_value.rb`
- `lib/webui/server.rb`
- `lib/webui/service.rb`
- `lib/webui/settings_form.rb`
- `lib/webui/submission.rb`
- `lib/webui/tree_builder.rb`
- `lib/webui/validator.rb`
- `lib/webui/viewer_store.rb`
- `lib/webui/websocket.rb`
- `lib/webui/window_geometry_store.rb`
- `spec/webui/webui_checkbox_indicator_fixture.html`
- `spec/webui/webui_compact_presentation_test.cjs`
- `spec/webui/webui_empty_frame_fixture.html`
- `spec/webui/webui_entry_intrinsic_fixture.html`
- `spec/webui/webui_renderer_fixture.cjs`
- `spec/webui/webui_renderer_test.cjs`
- `spec/webui/webui_selected_row_fixture.html`
- `spec/webui/webui_separator_fixture.html`
- `spec/webui/webui_table_editor_test.cjs`
- `spec/webui/webui_textarea_requisition_fixture.html`
- `spec/webui/webui_treeview_paint_fixture.html`
- `spec/webui/webui_treeview_paint_fixture.js`
- `spec/webui/webui_window_geometry_test.cjs`
- `spec/webui/webui_window_isolation_test.cjs`
- `spec/lib/common/script_scope_redux_spec.rb`
- `spec/lib/common/script_scope_widgets_spec.rb`
- `spec/lib/webui/adapter_factory_spec.rb`
- `spec/lib/webui/adapter_spec.rb`
- `spec/lib/webui/assets_spec.rb`
- `spec/lib/webui/bounded_contract_spec.rb`
- `spec/lib/webui/browser_launcher_spec.rb`
- `spec/lib/webui/compact_presentation_spec.rb`
- `spec/lib/webui/contract_foundation_spec.rb`
- `spec/lib/webui/contract_spec.rb`
- `spec/lib/webui/dispatcher_spec.rb`
- `spec/lib/webui/file_service_spec.rb`
- `spec/lib/webui/future_spec.rb`
- `spec/lib/webui/image_size_spec.rb`
- `spec/lib/webui/list_settings_form_spec.rb`
- `spec/lib/webui/modal_coordinator_spec.rb`
- `spec/lib/webui/native_legacy_presentation_spec.rb`
- `spec/lib/webui/native_typography_spec.rb`
- `spec/lib/webui/page_spec.rb`
- `spec/lib/webui/protocol_spec.rb`
- `spec/lib/webui/runtime_spec.rb`
- `spec/lib/webui/sensitive_value_spec.rb`
- `spec/lib/webui/server_spec.rb`
- `spec/lib/webui/service_spec.rb`
- `spec/lib/webui/settings_form_spec.rb`
- `spec/lib/webui/tree_builder_submission_spec.rb`
- `spec/lib/webui/validator_spec.rb`
- `spec/lib/webui/viewer_store_spec.rb`
- `spec/lib/webui/websocket_spec.rb`
- `spec/lib/webui/window_geometry_store_spec.rb`
- `spec/lib/webui/window_lifecycle_spec.rb`
