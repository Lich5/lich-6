# Native script beta status

Owner acceptance, October 6, 2026: `map.lic`, `go2.lic`, `soundfx.lic`,
`repository.lic`, `ewaggle.lic`, `creaturebar.lic`, and
`calibrate_creaturebar.lic`, `ebounty.lic`, `ecleanse.lic`, `eherbs.lic`, and
`eloot.lic`, `bigshot.lic`, `BlackArts.lic`, `bardwag.lic`, and `jinx.lic`
are ready for beta. All 15 conversions are owner-confirmed beta-ready.
This supersedes earlier open acceptance
items for those scripts; it does not claim their recorded host differences
were technically eliminated.

| Script | Status |
| --- | --- |
| map | Beta-ready: owner confirmed |
| go2 | Beta-ready: owner confirmed |
| soundfx | Beta-ready: owner confirmed |
| repository | Beta-ready: owner confirmed; see repository-webui-review.md |
| ewaggle | Beta-ready: owner confirmed |
| creaturebar | Beta-ready: owner confirmed |
| calibrate_creaturebar | Beta-ready: owner confirmed |
| BlackArts | Beta-ready: owner confirmed |
| bardwag | Beta-ready: owner confirmed |
| bigshot | Beta-ready: owner confirmed |
| ebounty | Beta-ready: owner confirmed |
| ecleanse | Beta-ready: owner confirmed |
| eherbs | Beta-ready: owner confirmed |
| eloot | Beta-ready: owner confirmed |
| jinx | Beta-ready: owner confirmed |

Preserve original calculations, defaults, timing, persistence, cancellation and
game behavior, including existing quirks. New core changes require owner
approval. Source validation and installed override status are separate.

See [Ewaggle and CreatureBar review](ewaggle-creaturebar-review.md) for the
October 6 changes, validation, and remaining checks. No override was installed
for these three scripts. BlackArts and Bigshot's intentional empty GTK labels
were addressed in the final-four review below.

See [the four E-script review](e-four-webui-review.md) for the grouped October 6
pass. ELoot's five intentional blank frame labels were restored in script source.
That group pass brought the owner-confirmed beta-ready count to eleven; the
final-four acceptance brings it to fifteen. No overrides were installed during
the E-script group pass.


## Final four — October 6 practical review

Reviewed in the requested order: Bigshot, BlackArts, Bardwag, Jinx. Frozen GTK
reference: scripts commit `7fd0b971387492cfd81b4bc7ef94428413965071`.
Actual GUI controllers ran with disposable settings and host/catalog boundaries;
no game commands, real package installations, or live repository fetches occurred.

- **Bigshot:** visited all eight native tabs against the original GTK build;
  loaded a full profile, changed its hunting room, and saved with Close. Restored
  five intentional blank frame labels, the original fog-choice display fallback,
  and footer alignment. Profile frames now share a natural grid width and scroll
  together. Real OS drag reduced the window from 1080×800 to 688×500; close/reopen
  restored that smaller window. Original missing-tooltip and incomplete-profile
  exceptions were not changed in production.
- **BlackArts:** reviewed all five tabs; default guild/availability callbacks ran
  against fixture host data. Reset Reagent Buying populated the original list;
  editing a creature name and Close saved it while retaining the profile. Fixed
  saved-profile display, two blank labels, header/footer alignment, and no-wrap
  lists. The existing notebook `size_to_all` property now includes the widest tab
  in natural sizing. Native launch was 842px wide versus GTK's 848px on this host;
  no screenshot-derived width was hardcoded. OS zoom/unzoom and Close worked.
- **Bardwag:** no source changes in this pass. Actual setup entrypoint, spell
  transfer, empty/populated peer lists, sonic weapon save, OS zoom/unzoom and Close
  worked. Native natural width was 622px versus GTK's 626px. Existing Cancel and
  coercion tests pass. GTK's invalid TreeView column warnings remain original.
- **Jinx:** actual `GUI.start!` used the default catalog/command/directory paths
  with disposable implementations at those external boundaries. Info reached
  `alpha.lic` in `fixture`; keyboard search produced the no-results message and
  Clear restored the records. Removed the script's forced light theme and white
  information background; the existing read-only log control now paints the
  information text with the application palette and preserves long text. GTK
  light/dark references and native light/dark rendering were compared. All four
  tabs were inspected; actual OS resizing reached 800×550 and 1300×850, followed
  by OS close and host shutdown. The accepted
  paging above 20,000 records remains unchanged.

The owner explicitly approved two focused renderer fixes: editable choices show
labels while submitting IDs (including refresh/free text), and frames preserve
natural grid minima. Both live in `lib/webui/assets/app.js`; two failing-before
fixtures were added to `spec/webui/webui_compact_presentation_test.cjs`. No shim
API, script-name renderer cases, or new styling system was introduced.

Validation: final Bigshot/BlackArts/Jinx plus non-UI parity run: 74 examples,
0 failures, 4 gated browser examples. Bardwag: 4 examples, 0 failures, 1 gated
browser example. A separate native/shim-consumer run passed 74 examples with
6 pending. The initial renderer run passed 80 checks but could not resolve jsdom
for the older suite. On October 6, the local test dependency was declared and
locked under `spec/webui`; a clean `npm ci --prefix spec/webui` followed by
`npm test --prefix spec/webui` passed all 99 checks, with zero failures or skips
(Node 26.5.0, jsdom 30.1.2). No production changes or assertion changes were
needed to close this dependency gap. CI integration remains pending. Ruby syntax,
JavaScript syntax, and whitespace checks pass.

Owner acceptance, October 6: Bigshot, BlackArts, Bardwag and Jinx are beta-ready,
including the recorded small typography and natural-size differences. Live
game/catalog use and script-specific persistence and independent-window checks
not explicitly described above remain beta follow-up areas, not claimed test
results. Jinx pointer
resizing initially returned `noWindowsAvailable`; a fresh app-window launch
completed the resize checks. No unresolved host blocker remains from that error. Historical acceptance gaps are not
silently closed by reused unit tests or these practical comparisons.

This pass changes script source only for Bigshot, BlackArts and Jinx, plus the
explicitly authorized renderer/test files and this status record. Installed
scripts and unrelated working-tree files remain untouched. No staging, commit,
or push was performed.
