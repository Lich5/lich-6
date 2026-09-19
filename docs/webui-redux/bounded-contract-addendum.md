# Bounded compatibility addendum

Doug approved this scope on 2026-09-17 after the review through Nisugi's 2.19.
This is lich-6's additive 2.6.0 contract, not an adoption of the lich-5 2.19
contract. The 29 component types and ten adapter operations remain unchanged.
Native-only typography was subsequently admitted in contract 2.7.0; see
`native-typography.md`. That decision does not widen this shim addendum.

## Admitted behavior

- Plain text input focus notifications carry no value and no submission. They
  are ordered events, not replaceable state updates. `alias` and `vars` use
  focus to clear placeholders, enable controls and append an editable row.
- Scroll reports carry bounded vertical position, content extent and viewport
  height, per viewer. The corresponding requested position is also per viewer.
  These support the actual adjustment arithmetic in `alias` and `vars`.
- Measured layout requests may use asymmetric margins, grid proportions and
  child packing. Each addition needs a source consumer and a behavioral spec.
  Grid row/column gaps are independent integers in 0..64 (`sellunder`), and
  explicit column/row placements preserve table cells. Offset plus span cannot
  exceed the declared column count. Scroll extents cannot be below viewport size.
- Existing 2.5 component implementations may be completed as consumers need
  them. No new type is implied by a missing renderer.
- Dynamic-row interactions may retry once after an explicitly correlated stale
  generation refusal. Optional positive integer request identifiers identify
  the refused browser intent; they grant no routing authority. The server sends
  the refusal before its current tree and never invokes the stale callback.
  Retained intents expire after 30 seconds, are capped at 256, and are discarded
  on disconnect, page destruction or clearing any sensitive field in their
  submission scope. Retries require the original binding and unchanged scope.
  Scroll measurements are refreshed rather than replayed as user intent.

## Invariants

Sensitive values travel only with terminal submissions. Focus never submits a
form, and changing focus must not lose unsent text or repeatedly trigger itself
after a render. Browser drafts and scroll measurements remain viewer-local.
Dynamic rows preserve stable identity and existing values. Modal dialogs must
not block the owner's dispatcher while awaiting a response on that dispatcher.
Closing a page must not discard edits before a save decision can be made.

Changing a select's options resets a removed default to its first declared
option; each viewer retains a still-valid selection or receives that default.
The shim's permanent blank choice represents GTK's -1 selection. Selection
normalization does not fabricate a script callback.

The localchat/status-monitor text buffer supports measured append and range
operations only. It renders literal text, retains the latest 1000 lines, refuses
lines beyond the existing 4096-character contract bound, and reports retention
as a degradation. No source HTML, GTK CSS, Pango font, or text tag reaches the
browser as executable markup. Spell overlays and log rendering implement
existing component types. Arbitrary styling remains a reported degradation.

The compatibility namespace remains script-only. Builder, models, Cairo,
GdkPixbuf drawing and native GTK loading remain forbidden. Unknown operations
fail with script and source attribution. The frozen evidence stays unchanged;
script corrections are separately hashed and tested from Projects/scripts.

## Deferred work

Navigation, menus, selectable cards, shapes, zoom, arbitrary styling and password
change/retention changes are not admitted by this addendum. A native library
proposal needs observed or credible use by three consumers. A hypothetical
future consumer is not grounds to enlarge the shim.

## Evidence

Behavioral specs precede implementation. Actual source execution and meaningful
browser interactions remain required for each population row. Automated results,
source corrections and independent/human acceptance are recorded separately.
