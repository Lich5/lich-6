# R4 population reconciliation

## Version pilot: resolved by owner, 2026-09-17

The frozen shim population uses `Gtk::Version::STRING`; its actual version pilot
is `eo-scripts/scripts/heal_spellup.lic:40`:

```ruby
gtk3_Active = (Gtk::Version::STRING.chr == '3')
```

All nine `Gtk::Version::MAJOR` gates occur in scripts designated for direct native
conversion: BlackArts, bigshot, ebounty, ecleanse, eherbs, eloot, ewaggle, go2 and
repository. They are Builder consumers outside this shim's population.

The owner approved replacing the R4 requirement for an actual MAJOR-gated shim
pilot with the STRING-gated pilot. This changes the test selection, not the
GTK 3 compatibility requirement or the prohibition on loading native GTK.
The frozen sources and the canonical design package remain unchanged.

## Known source defect

`dr-scripts/status-monitor.lic:284` calls `Gdk::RBGA.parse('red')` in the health
below 75 branch. This is the existing transposition of RGBA already recorded by
the architecture. It must be reported as a source defect, not silently accepted
as an extra shim API. Frozen evidence is not edited to hide it.

`eo-scripts/scripts/perfume.lic:35` handles window close only by calling
`Gtk.main_quit`; its wait at line 73 depends on `window_action`, which that
handler never updates. Save and Exit set the variable. The shim dispositions
native main-loop calls as lifecycle-only under contract 11.5; it must not invent
a global script-kill side effect to hide this source defect. The close path
needs a script correction during alpha; the frozen source remains unchanged.

`eo-scripts/scripts/betazzherb.lic:129,132` packs the same horizontal box into
the same parent twice. The shim keeps one widget identity and reports the
duplicate with source attribution; it does not create duplicate form inputs.
The script also creates its spell checkboxes conditionally at lines 79 and 83
but accesses them unconditionally immediately afterward. The current successful
path supplies both spells. Characters missing either spell require a source
correction; that branch is not represented as passing evidence.

## Core defects exposed by the pilots

- The adapter had no delivery path through its ten public operations; tests
  flushed it privately. Delivery now runs in the core scheduler, with owner
  cancellation and render-lock ordering fixed.
- Adapter viewer writes were incorporated into a common render definition,
  and callback reads did not consult the originating viewer. They now route
  through the core viewer store; a two-viewer regression protects isolation.
- The browser lacked the already-contracted grid renderer. The renderer now
  handles children and spans, with DOM tests and actual MyFletch browser proof.
- Blur-triggered rendering could invalidate the immediately following Save.
  Nonstructural local drafts no longer trigger a redundant generation; terminal
  form submissions still capture the server-declared scope.
- `Script.self.kill` could return before cleanup stopped its caller, letting
  heal_spellup leave setup and enter gameplay. Self-kill now exits that worker;
  external callers retain asynchronous cleanup. The lifecycle regression suite
  passed 182 examples after this correction.

## Evidence still required

Static reconciliation identifies 26 EO and three DR plain-widget scripts after
excluding the six owner exclusions, fifteen direct UI conversions and two
version-reporting/non-UI scripts. Static inventory alone is not consumer proof.
Ordered execution traces, the measured class union and browser/event acceptance
for all 29 remain required before declaring R4 complete. The generated population
file records incomplete rows explicitly and verifies the exact frozen hashes.
All 29 rows now have a runtime/browser path, using corrected sources where
necessary. Nineteen frozen-source traces and ten corrected-source traces are
kept separately. The generator verifies both sets of hashes and records the
effective browser count. This does not establish every branch or human acceptance.
The DR status monitor's below-75 health branch remains a known source failure.

The current traces record 24 distinct constructor receivers. This is not the
nominal 28-class inventory: Ruby-level constructor tracing excludes C-level
default constructors and objects obtained from getters (TextBuffer, Adjustment,
StyleContext), and unexecuted GTK2/dead helper branches are not evidence. The
full ordered operation records retain those distinctions. No calls or classes
are invented to force the count to 28.

## Architecture decision: incoming focus events

`alias.lic:151,169,239,257` and `vars.lic:127,145` use `focus-in-event` to clear
placeholder text, enable dependent controls and append rows. Contract 2.5.0
section 10.5 permits only `change` and `submit` for text inputs. Section 10.9's
programmatic focus facility operates in the opposite direction. Mapping focus
to change would alter source behavior; silently accepting it would conceal an
unsupported operation. R4 section 9 therefore requires a decision.

The owner authorized bringing the 2.17 review forward, with discussion before
any contract change. The review is in `contract-2.17-review.md`. Doug subsequently approved the bounded focus/layout/scroll addendum on 2026-09-17.
Implementation is now tracked in `bounded-contract-addendum.md`; the type count
and adapter operation count remain unchanged.

## Next architecture review, before conversions

The owner initially placed the review after the shim and before conversions,
then advanced it to resolve the focus-event gap above. The later owner approval authorizes only the bounded additions, not wholesale
adoption of 2.19. All fifteen native conversions now have local implementation
and fixture browser paths in Projects/scripts. Independent review/testing and
live-game acceptance remain pending; see `native-conversions.md`.


## Corrected script sources

Projects/scripts is now an authorized edit scope. Frozen evidence remains read-only.
`perfume` now exits its setup wait on host close. `betazzherb` removes duplicate
packing and guards optional controls; the original missing-spell calls were
swallowed by Lich's NilClass extension, not an observed crash in this runtime.
`vars` and `alias` have explicit Save & Close and Cancel actions so a terminal
submission occurs before the viewer disconnects. Alias retains a live service
owner and adopts its GUI worker; its old detached hook could outlive UI ownership.
Corrected-source traces are separate under `r4-corrected-traces/` and must match
those sources, not overwrite the frozen manifest's hashes. These are ongoing
engineering results, not independent acceptance or completion of R4.

Further corrections established by actual execution and browser checks:

- `armor`: replaced overlapping alignment offsets with real chart cells;
  preserves line breaks and chart text. The second chart now aligns all 23
  data rows; its narrow group column uses Soft lthr / Hard lthr abbreviations.
  The padding chart includes a Points heading. Wide charts need horizontal scrolling.
- `clearcheckwiz`: polls while idle, allowing pending refreshes and Close to
  complete without another game line, including initial response waits.
- `localchat`: removes an attempted second parent for its scroll widget and
  resets delimiter offsets for each recitation line, including short continuations.
- `mybounty`, `madwarrior`: explicit Save & Close and Cancel; host close cancels.
- `sbounty`: asynchronous error dialog, ComboBoxText removal without a model,
  nil/deleted-location guards and private editable copies until Save.
- `sellunder`: no explicit native gtk3 require; asynchronous validation dialog.
- `spellson`: initializes and updates the correct window-position variable;
  bounds progress to 0–1 when remaining time exceeds nominal duration or the
  duration is indefinite. Remaining-time text is retained.
- `alias`, `vars`: real placeholder properties replace fake placeholder values;
  focus initializes a new row without clearing freshly typed input.

Additional core/adapter fixes: numeric input reports edits before a tab change;
modal page announcements do not reattach an active form; option removal resets
only invalid viewer selections; terminal submissions establish the client's new
draft baseline so an intentional clear is not undone. Browser retries remain
bounded and correlated. Closed shim windows are released from their session.

Browser host navigation delivers the close lifecycle. Closing a tab through the
test host did not reliably deliver pagehide; disconnect therefore retains the
documented reconnect window. Do not claim tab-close delivery is guaranteed.


## Final local reconciliation, 2026-09-18

The current source regression passed 32 examples, zero failures (seed 61188).
Armor and Spellson browser traces were regenerated after their final corrections;
all 29 effective source/browser paths reconcile to the expected hashes. This is
not all-branch proof. The separate editable DragonRealms checkout has not been
located; `status-monitor-rgba.patch` is ready but unapplied. The frozen corpus
remains unchanged, and status-monitor's below-75 health branch remains blocked
on that source correction. Independent acceptance remains pending.
