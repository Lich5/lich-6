# Native Frontends tab

The fourth launcher tab carries the 5.21.0 frontend editor into native WebUI.
It preserves catalog columns, first-row selection, field order, built-in identity
locks, capability groups, and the Add Custom / Save / Delete Custom / Reload row.
Detection reports availability; editing never launches a frontend or changes an
account's frontend association.

## Reuse and changes

FrontendEditor, FrontendChoices, and the tab's presentation reuse Nisugi's
`webui/launcher` work (PR #1652, initial editor commit `edbd42b3`) as present in
the audited integration `19fad8ab1786798c62e96e4b8738dc4508f3920f`.
The reused code retains its original repository licensing.

The tab is a separate launcher collaborator instead of adding its controller
methods to the launcher. Discovery is cached outside rendering; file operations
run on the existing serial executor. Queued edits are cancelled on close,
overlapping edits are refused, and an altered or stale submitted identity cannot
redirect an edit to a different record. Existing frontend validation and atomic
file replacement remain authoritative.

Changing editor records replaces component identities. Browser testing found
that otherwise viewer-local drafts survived into the next record, including
Add Custom. Validation errors retain the same editor identity and draft.
The renderer now honors the existing `max_height` contract property, so the
catalog scrolls without pushing the form unnecessarily far down the window.

Catalog choices include configured custom frontends even when discovery cannot
find their executable. Unavailable built-ins remain visible with status, matching
the 5.21.0 selector; launch-time availability validation remains in place.

## Evidence

- Reused editor/choice and native tab tests exercise actual temporary settings files.
- Tests cover deferred writes, queued-close cancellation, overlapping saves,
  stale identity, field parsing, validation refusal, deletion and cached discovery.
- Authenticated browser testing created a custom frontend, edited its label,
  reloaded it, and verified the persisted command, capabilities and quoted argv.
  Tests used a disposable directory, never the owner's settings or live account.
- Browser testing verified the empty Add Custom form after the identity fix.
- This reordered delivery is based directly on the committed 5.21.0 baseline.
  Its native contract remains 2.5.0. Validation for this exact tree is recorded
  in the PR preparation report after the standalone checks complete.

## Core ownership and dependency boundary

This tab and its supporting presentation fixes are core functionality. It has
no dependency on the deferred shim PR, the script compatibility namespace, or
native script conversion support. The catalog's existing max_height property
is honored by the core renderer; the editor's stylesheet rules are scoped to
its own fields. Both corrections ship with this Frontends change. Regression
coverage in script/support/frontend_renderer_test.cjs protects catalog scrolling
and ensures the field layout does not alter unrelated forms.

Contract schemas, adapter/runtime/service, script lifecycle and script-scope
files remain unchanged from the baseline. The launcher acceptance probe adds the
fourth tab while retaining its 2.5.0 handshake. Independent review and
cross-platform/live frontend acceptance remain pending.
