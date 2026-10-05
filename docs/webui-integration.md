# WebUI integration onto proposed 5.22

Updated October 5, 2026. This describes the WebUI integration onto the proposed
5.22 baseline. Proposed 5.22 is a snapshot, not a released upstream tag.

## Baseline and sequence

- Integration repository: `Lich5/lich-6`. Paths below are repository-relative.
- EO main incorporated: `58ffd5f19b609df0a22c9060f8ad72781a2bc559`.
- Integration baseline:
  `b95e324823a2db71af72329236d556a47b28e4df`.
- The only baseline difference from that EO snapshot is `lib/version.rb`:
  `LICH_VERSION = '5.22.0'` instead of `5.21.0`.
- Current feature branch: `webui/01-foundation-shim`, based on `b95e3248`.
- The three old 5.21 WebUI PRs, #7, #8 and #9, are closed and unmerged.

| Slice | Scope | Branch | Publication |
| --- | --- | --- | --- |
| 1 | Existing WebUI foundation, browser host, renderer and bounded shim; selected correctness fixes | `webui/01-foundation-shim` | Initial import: `31158733` |
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
40 modified tracked files and 36 untracked files. The imported snapshot is
recorded in commit `3115873349912ae5a9c6c5e220fa918fc83c0a0a`.

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
| `lib/webui/adapter.rb` | Preserve distinct root identities in handle lookup and render batching, even when their properties are equal |
| `lib/webui.rb` | Resolve the active service before registering a native page after service shutdown |

These are changes to the imported core foundation, not script-specific
workarounds. Fourteen added regression examples cover them, including identity-based
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

Other #1648 proposals have not been adopted: queue performance changes,
a maximum served-file size, timed cancellation after a transient modal
disconnect, and Windows presentation/adoption changes. Revisit relevant lifecycle
cases during slice 2's actual launcher integration; do not represent PR 1 as the
whole of #1648 or all platform acceptance. A modal user-close now cancels it;
a transport loss alone retains the existing reconnect/timeout/owner-termination
behavior. No new reconnect grace policy is introduced in this slice.

## Validation and limits

CodeRabbit follow-up: three regressions reproduced the root-identity and service
restart defects before correction. After correction, the foundation/shim suite
passed 279 examples with zero failures and two browser-gated cases (seed 31271).
RuboCop found no offenses in the four changed Ruby files. The native restart
test stubs browser process creation; it does not claim OS-window acceptance.

The initial import at `31158733` had the validation results below. Browser-content checks
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
  87 additions pass whitespace checks.
- Final full 5.22 suite: **8,750 examples, zero failures, two browser-gated
  cases**, seed 63710, Ruby 4.0.5. Both gated cases passed separately above.

The first full run found only the shim test's assumption that global GTK was
absent (8,748 examples, one failure, two gated cases). That assumption conflicts
with this staged integration; the corrected test checks namespace preservation.
A first browser harness run used the wrong `hr` selector for the existing
`div.webui-divider`; correcting the disposable harness yielded the passing
browser run above. Neither issue required a product rendering change.

## Security review carried into native cutover

Owner-supplied security architecture review, recorded October 5, 2026, covering
PR #10 through `9a8d378e949b7da41f9f3119160a45da85130e50`. Overall assessment:
**Moderate**. The findings below are reported observations from that review,
not independently revalidated by recording them here. Keep them open and revisit
them at the start of slice 2, before native authentication integration. Recording
the review does not authorize a capability redesign or mark a finding fixed.

- **Medium, reported observed: repeated attachment retains viewer state.** An
  authenticated connection can repeatedly attach to one page without a resume
  token. Each attachment remains in the resume index while the connection index
  is overwritten. Disconnect/detach cleans only the latest mapping; older
  entries have no expiry, retain values, participate in refresh delivery, and
  can make an owner appear to have viewers after disconnection. Ordinary resume
  expiry and page destruction do not repair this repeated-attach path.
- **Inferred impact:** repetition permits persistent memory and render-work
  amplification affecting other pages in the shared host. This requires
  authenticated local access; it is not an unauthenticated remote attack.
- **Low, reported observed: canceled sensitive submissions bypass disposal.**
  Explicit disposal currently belongs to the callback's ensure block. Owner
  shutdown removes queued callbacks without running that block, and enqueue
  refusal after snapshot construction has no snapshot-disposal path. Both
  bypass SensitiveValue's overwrite-and-clear operation. Normal callback
  completion and raw-input scrubbing are countercontrols. This is a cleanup
  gap, not evidence of serialization leakage or externally accessible plaintext.
- **Reported trust boundary:** authentication grants service-wide visibility,
  not a page-specific capability. WebSocket greetings expose registered page
  descriptors, attachments resolve supplied page addresses, and file requests
  use the shared session cookie. Callbacks retain the selected page owner's
  authority. Owner attribution governs lifecycle, not viewer-to-owner access.
- **Existing controls reported by the review:** single-use launch tokens expire
  after 60 seconds; port-named cookies are HttpOnly and SameSite=Strict; Host and
  Fetch Metadata checks apply, with loopback Origin checks for WebSockets. File
  access requires authentication, image-extension filtering, permitted roots
  and realpath containment. Missing Origin on an authenticated file GET alone
  does not demonstrate a cross-origin bypass. Ordinary disconnect has a
  60-second resume window; page destruction clears viewer indexes and values.
  Owner termination cancels modals, revokes file routes, shuts down dispatch,
  unregisters pages and destroys viewer state. Normal startup is unchanged.
- **Proposed decision before native authentication:** document whether every
  authenticated viewer is trusted across all owners and registered file roots.
  If page-specific trust is required, assess explicit capabilities; opaque page
  addresses and owner attribution must not be represented as authorization.

## Publishing the same feature for EO review

Proposed PR title: **Add WebUI foundation and bounded script compatibility**.

Proposed description: Add the preserved WebUI renderer, authenticated loopback
service, native browser host, forms and script-local compatibility layer onto
the proposed 5.22 baseline. Correct callback ownership, viewer coalescing,
multi-session authentication, write deadlines and modal lifecycle issues with
focused regressions. Normal startup remains unchanged until the subsequent
native cutover PR. Validation and remaining platform/browser limits are recorded
in this document.

This feature's implementation base is the full `b95e3248` SHA above. CodeRabbit
reviewed initial import `3115873349912ae5a9c6c5e220fa918fc83c0a0a` and identified
the adapter identity, service restart and documentation issues corrected here.
PR descriptions should record the publication URLs and subsequent reviewed
commit range.

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
