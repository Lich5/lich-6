# Native script conversion requirements

Doug authorized all fifteen conversions on 2026-09-17. These consumers use
native WebUI and do not enter the GTK compatibility namespace. Business/game
logic and settings formats remain the script's responsibility.

## Population and acceptance

| Script | Required UI behavior |
| --- | --- |
| BlackArts | Setup fields, profiles, lists and action controls |
| bardwag | Known/cast spell lists, ordering, target/options, Save and Cancel |
| bigshot | Complete setup including profiles and editable boon behavior |
| calibrate_creaturebar | Calibration selection and measured geometry controls |
| creaturebar | Live creature presentation and existing actions/settings |
| ebounty | Setup, profiles, destinations and task options |
| ecleanse | Setup, lists and existing save semantics |
| eherbs | Setup, profiles and herb-specific controls |
| eloot | Setup, editable lists, profiles and sorting behavior |
| ewaggle | Setup, spell choices and options |
| go2 | Travel settings, preserves existing load/save normalization |
| jinx | Repositories, scripts/data search, information, explicit actions and log |
| map | Map image/regions, navigation and settings using native declarative UI |
| repository | Search, selection, details and explicit repository actions |
| soundfx | Add/edit/remove trigger-to-sound mappings, Save and Cancel |

The exact current source must be audited for each row before implementation.
No row is complete because a generic settings screen exists. In particular,
Nisugi's bigshot conversion leaves profiles and boon arrays dependent on GTK;
that restriction cannot be carried into this migration.

## Implementation rules

- Write behavior specs first. Exercise the actual script entrypoint where
  practical, including current values, edits, final persistence, cancellation,
  closure and owner termination. Fixtures replace game/network/audio effects;
  they do not replace the production UI implementation.
- Delete obsolete Builder classes, XML, model code and GTK initialization from
  converted scripts. No runtime XML translator, legacy fallback or new shim
  capability may be introduced to ease a conversion.
- Reuse data mappings and business normalization from reviewed local submissions
  where correct. Recast presentation through this repository's Page/TreeBuilder
  contract; the other branch's UI API is not an implicit dependency.
- A native library may factor repeated form ownership/submission behavior with
  at least three identified consumers. It belongs outside the shim. Avoid a
  generic toolkit or a second event loop. The core owns delivery and dispatch.
- Keep unsaved input viewer-local. Persist only the server-declared terminal
  submission. Cancel and host close cannot silently save. Dynamic controls use
  stable identities and explicit refreshes; rendering performs no I/O.
- Reuse the existing 29 component types. Implement missing renderers to their
  contract with browser tests; do not silently substitute an unsupported view.
- Add no dependency installation, network exercise, publication or live-game
  action to validation. Use the owner's verified rubystd session for Ruby.

## Status

All fifteen native controllers now have local implementations and at least one
fixture browser path. BlackArts, bigshot and eloot have joined the initial twelve.
Bounded native typography is implemented under the approved fit assessment.
These results are local fixture acceptance, not live-game or independent
acceptance. No row is independently accepted or claimed to cover every branch.
The current source hashes and validation counts are in
`native-progress-evidence.json`. Shim evidence and the unresolved DR source
correction are tracked separately in `r4-shim-population.json` and
`r4-shim-discrepancies.md`.


## First six native controllers — local evidence

The source acceptance harness is `script/support/native_conversion_spec.rb`.
Fourteen controller examples passed (seed 35440); the first six browser cases
passed in one run (`--example browser --order defined`, 123.6 seconds). Ruby
validation uses the owner's interactive rubystd Ruby 4.0.5 session. All file,
audio and game effects were fixtures. SoundFX and Bardwag were edited and saved;
EHerbs rejected 120% stock, retained the draft and saved corrected 75% stock;
Ewaggle saved a spell choice; Ecleanse saved disarm preferences; Go2 saved a
trinket and delay. The browser run did not install, download, play audio, or
issue game commands.

`Lich::WebUI::SettingsForm` factors only the terminal form workflow shared by
Go2, Ecleanse, Ewaggle, EHerbs and Bardwag. It returns a copied Save result to the
script thread; Cancel and host close return nil. Rendering performs no I/O.
SoundFX owns its row editor because its add/delete behavior is different.
Neither adds a shim method. The native multiline renderer implements the
existing textarea contract for Bardwag's explicit cast order.

Ewaggle uses checkbox membership instead of dragging between two model lists.
Bardwag uses an ordered list of spell numbers with a known-spell reference;
this preserves editable cast order without adding drag-and-drop primitives.
SoundFX uses a Delete-on-Save checkbox so removal cannot discard another
viewer's unsaved row immediately. All three retain the relevant settings
formats. EHerbs preserves runtime metadata outside its thirteen form fields,
including prices; the previous Builder setup deleted those keys.


## Native additions after the initial six

Repository uses stable row keys for search, sorting, comments and an explicit
download closure bound to the displayed record. Its fixture browser path passed
(seed 51482); no repository download was performed.

Jinx replaces the old GTK controller and does not import the global-logger
constant swap from either submission. Its one worker captures output on that
thread only, belongs to the owning script group, and refuses overlapping work.
Rendering reads cached data. Repository mutation inputs and force overwrite
arrive in terminal submissions. Browser search, information, update, repository
and log tabs passed with fixture actions (seed 35783). The tests also cover
invalid URLs, cancellation and a blocked worker. The final browser rerun exercised the sort binding, search, information and
explicit update with force enabled (seed 62851, seven examples, zero failures).
The one-row fixture verifies event delivery, not multi-row sort order.

EBounty replaces Builder with 183 controls across eight viewer-local tabs.
Resting and hunting modes are exclusive choices. Existing profile files are
listed, exclusions remain arrays, all thirty escort routes are represented,
and ability gates are enforced again on Save. Browser edits across Resting,
Exclusions and Profiles passed (seed 3124). No game command or real profile
write was performed.

Map uses the existing composite image/bar/label/region vocabulary, not a shim
canvas. Map categories, current/found/tag/location/note markers, coordinate
fallbacks and fixed map links reuse the prior scripts' data rules. Find is
temporary; Apply settings and Save note are explicit. The two-corner correction
refuses to combine clicks made in different rooms. Its fixture browser path
passed (seed 60430), including a note and scale change. Native pointer travel,
follow updates, dark assets and correction branches still need expanded browser
acceptance and live-game testing. Marker output is bounded with an explicit
notice when the display limit is reached. Browser window placement, decoration
and always-on-top replace platform GTK window-manager controls. Zoom is an
explicit scale control; no 2.19 wheel event or generic drawing vocabulary is
introduced. Horizontal pan retention is client-local and adds no shim event.

`Lich::WebUI::ImageSize` reads bounded PNG/GIF/JPEG headers for native image
consumers without a graphics dependency. The composite renderer reuses the
reviewed layer model and portions of Nisugi's rendering approach, with actual
mask tinting, scaled layout, no doubled scroll offset in click coordinates, and
no import of GTK pointer shims or the unapproved shape/zoom events.

## CreatureBar and calibration — provisional native implementation

The two scripts share `NativeAssets` and `NativePanel` in the existing
`creaturebar.lic`; loading those definitions from the calibrator does not start
the dashboard or invoke asset installation. Each controller owns its page,
future and file registration. Neither loads GTK or installs process-wide signal
handlers. The domain presentation is shared; no new generic toolkit or shim
method was added.

Wound positions retain unscaled image coordinates and independent marker sizes.
Calibration saves preserve unknown metadata; copying display settings preserves
each destination's wound coordinates and reports per-file failures. Save uses a
temporary sibling and rename. Preview changes and closure do not write files.
The live dashboard samples combat data outside rendering and targets a stable
creature ID. Name emphasis, health thresholds, status text/color indicators,
image tint and marker opacity use the existing native vocabulary.

The source harness `script/support/creaturebar_native_spec.rb` covers both complete
script imports, coordinate transforms, health bounds, target identity, explicit
Save/Cancel and metadata preservation. The first pair of browser cases passed;
a subsequent calibration rerun after layout changes passed (seed 26112). Browser
inspection corrected fixed-height overlap and embedded health text clipping.
The intermediate second calibration run ended before saving while work switched
to the owner's contract question; it is not counted as a passing run. These are
fixture results, not live combat or independent acceptance.

Doug approved implementing typography when its fit was high. The assessment in
`native-typography.md` admits a smaller typed native subset than Nisugi's Pango
markup support: bounded point sizes and structured foreground/background RGBA
on literal text and composite labels. Contract 2.7 retains the 29 types and
ten adapter operations. Creaturebar's name/HP/status font sizes and text colors
now render, and the calibrator edits them. The browser fixture saved 18/14/16pt
values and verified their actual rendered sizes and colors (seed 19449).
Window placement, decoration and always-on-top remain browser-managed. Arbitrary
font families are not imported, and there is no GTK style forwarding.

Map follow status now distinguishes the temporary paused state from the next
Apply choice. Current/found markers take priority over optional markers at the
layer bound, and per-map scale changes preserve the global fallback scale.

## Final three native controllers

Eloot preserves loot/sell memberships, custom choices, runtime inventory,
exclusive tipping/hoarding modes and locker selection. Editable lists use one
item per line; scroll spells retain their vibrant suffix. Incremental tip preview
uses the existing domain calculator with the submitted draft and never saves.
Plain helper text preserves the former tooltip explanations without markup.
Save persists on the script thread, with memory restoration on a write failure.
Browser preview, tab switching and Save passed (seed 44530).

BlackArts preserves its ten hunting profiles and ingredient routes, ability
gates, guild selection and default buy/consignment lists. Reset changes the
submitted draft and does not persist. Reset/load actions explicitly replace
input identities so older dirty browser values cannot override them. The browser
exercised repeated reset, hunting profile selection and Save (seed 20728).

Bigshot replaces all setup controls, including profiles and individual/group
boon choices. Profile file operations run on the owning script thread; overwrite
requires an explicit checkbox. Names reject traversal, profile-file symlinks are
refused, YAML loading is bounded and safe, and writes use a temporary sibling.
Named-profile Save writes that named file; Save & Close separately updates active
settings. Cancel does not undo an explicitly saved named file. The old interaction
alert also has a bounded native page owned by its monitoring script. Browser
profile load, hunting-room edit, individual boon change and Save passed
(seed 50641). Live group/combat and interaction-alert integration remain alpha
acceptance work.

## Final regression and review findings

The combined source regression passed 73 examples with zero failures (seed
33812); fifteen browser cases are intentionally pending in that non-browser run.
Each has separate browser-path evidence. Eloot's later helper-text edit passed
its affected suite (five examples, zero failures, one browser case pending,
seed 21190). The core suite passed 7,188 examples (seed 58877), and the renderer
suite passed nineteen tests. All fifteen complete script files compiled on the
owner's rubystd Ruby 4.0.5. These counts are separate suites, not one aggregate.

Review fixed nil saved defaults in Ecleanse/EHerbs/Ewaggle; Go2 now tests the
submitted FWI off value; SoundFX rejects an oversized initial catalog clearly;
Jinx releases a gated worker if owner adoption fails; launch failures release
pages. Shared form normalization preserves drafts on validation failure.
Map filters expose tag/location choices beyond a single select's bound, while
retaining current selections. The final Map browser run covered filtering,
Find, note Save and scale Save (seed 13389). Pan/center have DOM renderer tests;
full live map navigation, dark assets and correction workflows still need alpha
coverage.

Creaturebar uses existing composite bars for silhouette background and target
borders, preserving configured colors within the native content. Browser window
chrome remains browser-managed. The final dashboard browser run verified the
gold target border, stable target action and Close (seed 31057). Calibration
marker tint is preserved. Global configuration saves use a temporary sibling,
flush/fsync and rename. That file and DB_Store are separate persistence stores;
a failure between writes is not a joint atomic transaction.
