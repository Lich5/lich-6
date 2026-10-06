# Ewaggle, CreatureBar and calibrator review — October 6, 2026

## Owner beta acceptance

After the frame-spacing repair and updated comparison, the owner accepted
`ewaggle.lic`, `creaturebar.lic`, and `calibrate_creaturebar.lic` as ready for beta
on October 6, 2026. This supersedes the earlier pending acceptance statuses below.
Recorded differences and unperformed checks remain historical evidence and beta
follow-up items; acceptance does not mean they were technically eliminated or
performed. This status update changes documentation only and installs no scripts.

## Review record preceding acceptance

Current core: `webui/04-theme-abstractions`, based on `901733ec` plus local
changes. Conversion source: Projects/scripts, frozen GTK reference
`7fd0b971387492cfd81b4bc7ef94428413965071`.

The owner confirmed Map, Go2, SoundFX and Repository ready for beta. This review
does not reopen their acceptance. None of the three scripts below is newly
declared beta-ready or installed by this review.

## Changes made in this review

| File | Change |
| --- | --- |
| Projects/scripts/scripts/ewaggle.lic | Use the approved table `wrap: false`; use existing `setup_footer` with the same wording/callback; explicitly retain the original empty GTK label widget with a nonbreaking-space label. CRLF preserved. |
| Projects/scripts/scripts/creaturebar.lic | Remove forced light mode from appearance settings and two child dialogs; choose the original dialog surface color for the current theme. Preserve the explicitly dark dashboard. Omit the panel frame label, matching the original `Gtk::Frame.new`. |
| lib/webui/contract.rb | Owner-authorized follow-up: make the existing group label optional so absence differs from an explicitly blank label. The earlier table wrapping change remains separate. |
| lib/common/script_scope/gtk/widgets.rb | Preserve the absent label in `Frame.new` / `Frame.new(nil)`; retain explicit empty/named labels and `set_label_widget`. |
| lib/webui/assets/app.js | Mark existing zero-border groups and explicitly blank labels for shared presentation. |
| lib/webui/assets/app.css | Reserve the synthetic label row only for explicitly blank bordered groups; unlabeled frames have none. |
| spec/webui/webui_compact_presentation_test.cjs | Failing-before regression covering absent, blank, named and borderless groups. |
| spec/lib/webui/bounded_contract_spec.rb, spec/lib/common/script_scope_widgets_spec.rb | Failing-before optional-label contract and actual shim render regressions. |
| docs/repository-webui-review.md | Record the owner's beta acceptance. |
| docs/native-script-beta-status.md | Current status for all 15 conversions. |
| docs/ewaggle-creaturebar-review.md | This review and remaining acceptance checklist. |

No calibrator source edit. No calculation, default, coercion, timing, persistence,
cancellation or game-command change. The earlier Repository no-wrap changes in
the contract, renderer and tests remain separate pre-existing work.

The shared correction was explicitly approved after a real browser measurement:
a zero-border surface had a 15px `::before` spacer. Afterward that surface has no
pseudo-element; framed/default groups retain their prior behavior. Ewaggle's
frozen Builder XML explicitly supplies a blank label widget despite having no
frame shadow, so its space is retained through a real label, without hardcoding
window dimensions. Its table starts at approximately y=84.6 versus GTK y=84.

## Results and remaining acceptance

| Script | Completed checks | Still open |
| --- | --- | --- |
| Ewaggle | Original GTK captured in light/dark, full/empty states at requested natural, smaller and larger sizes. Native full light and empty dark views compared; 730×800 layout and 976×960 stretching checked. Smaller browser viewport preserves the 730×800 content minimum. Actual spell transfer, field edits and Close persisted expected values. Controller tests cover cancellation and same-list duplicate behavior. Actual Chrome app OS close, menu resize and reopen exercised. | Owner visual/live-use acceptance; exact native popup/focus paint; original keep-above behavior is not provided. Minor tab emphasis, checkbox/stepper paint and dark shade differences remain. |
| CreatureBar | Actual GTK dashboard with copied artwork, head injury, 75/100 HP and stunned status; empty and enlarged GTK views. Native dashboard actual OS window, populated/empty, panel click targeted fixture ID 42, context menu inspected. Real update loop opened settings; closing settings left dashboard connected. All six original settings tabs captured in both themes. Dark native parent/editor/warning verified, status added, Apply retained permissive `2cats`→2 coercion. Actual OS close releases the host. | False empty-label panel spacing is now fixed (follow-up below); small natural-size/alignment differences remain. Always-on-top, decoration and transparency controls are disabled; original Alt-drag has no equivalent. Complete matched larger/smaller dashboard comparison, selected/disabled paint, reopen/position restoration and live combat review remain. |
| calibrate_creaturebar | Actual frozen GTK controller and real artwork at natural 438×623, smaller request clamped to that minimum, and 900×1000. Actual Chrome app tabs, scale and name/HP/status font edits, Save and confirmation dialog exercised. Saved fixture YAML had scale 1.5 and font sizes 18/14/16. OS menu resize and OS close saved geometry and stopped host. Automated tests cover coordinate arithmetic, copy-settings preservation, cancellation, imports and entrypoint wiring. | Original explicit GTK CSS is not reproduced: compact flat buttons, entry dimensions/colors, label colors and tab sizing differ. Native initial window was approximately 327×689, versus GTK 438×623 with the same artwork. Do not replace dynamic requisitions with those screenshot dimensions. Live pointer wound placement, complete popup/resize comparison and matched-config OS reopen/position restoration remain. |

Ewaggle's OS quarter-window action saved 1280×626 at [0,30]; reopening applied
its 800px content minimum. Closing the independent calibrator window left the
Ewaggle app connected. This is actual OS evidence. Browser viewport changes
and closing content-check tabs are not counted as OS-window evidence.

Native pointer access was intermittent (`noWindowsAvailable`). Native
accessibility controls, menus and close actions worked; calibrator text edits
and a CreatureBar panel click also worked. Fresh accessibility IDs are required
after every render. No blank Chrome windows/tabs were opened for testing or
cleanup. Owner windows were preserved.

## Validation

- Focused Ruby suite: **118 examples, 0 failures, 7 pending**. Includes native
  controller/default/entrypoint tests, frozen non-UI source guards, bounded
  contract and shim widget/redux checks. Pending browser examples were not
  silently promoted to passing by separate manual interactions.
- Renderer fixtures: **78 checks passed** across compact presentation, tables,
  geometry and window isolation. The standalone `webui_renderer_test.cjs`
  could not load because `jsdom` is unavailable; no dependency was installed.
- Ruby syntax passed for all three script sources.
- Core `git diff --check` passed. Script checks passed with
  `core.whitespace=cr-at-eol`, preserving Ewaggle's existing line endings.
- Both new regressions failed before their repairs: Ewaggle table wrapping and
  CreatureBar inherited dark mode. The shared borderless-group fixture also
  failed before the renderer repair and passed afterward.

Disposable fixtures/results are under `/private/tmp/native-next-review`.
They load actual frozen/current UI definitions and stub only game data, external
persistence and the script host. They do not establish a live game session.
The first calibrator save used the spec helper's temporary data directory;
subsequent fixtures use the explicitly named disposable directory. Neither used
installed game configuration for writes.

## Scope and next decisions

Installed CreatureBar assets/configuration were read and copied with explicit
owner authorization. Installed originals remain unchanged. No override was
installed for Ewaggle, CreatureBar or the calibrator.

The initial borderless fix did not resolve framed groups; the separately
authorized follow-up below corrects absent frame labels. The calibrator's custom
control styling remains outside this fix. Further shared-control changes require
a separate owner decision. BlackArts, Bigshot and ELoot also use zero-border groups; their
pending reviews must distinguish actual blank GTK label widgets from plain
layout surfaces. None of the four beta-approved scripts uses a zero-border
group; SoundFX's zero-border table is unaffected by this group-only correction.

## Follow-up: unlabeled panel frame

The owner authorized correcting the remaining panel offset after reviewing the
side-by-side images. The original `Gtk::Frame.new` has no label widget. The
conversion previously supplied `label: ''`, and the renderer reserved a 15px
blank-label row. The group contract now permits omitting the label; CreatureBar
does so. Existing explicitly blank labels keep their previous presentation.
No negative margins or captured window dimensions were introduced.

Real browser measurements verified both native groups and actual shim Frames:
absent label → no pseudo-element; explicit blank label → approximately 15px;
named labels → ordinary legend. Borderless native groups remain unchanged, and
Ewaggle's explicit nonbreaking-space legend still measures approximately 15px.
The production Chrome CreatureBar app was captured with the same copied artwork
and creature data, then closed through its OS close button; its host stopped.
The false label row is fixed. Other dashboard size, paint and desktop-behavior
acceptance items above remain open; this is not full beta acceptance.

Current validation: **120 examples, 0 failures, 7 pending**; **78 renderer checks
passed**; **4 Ruby files inspected by RuboCop, no offenses**; CreatureBar syntax
and whitespace checks pass. The new contract/shim examples and renderer fixture
failed before the repair. The previously reported missing `jsdom` limitation
remains. Updated actual-render comparison:
`/private/tmp/native-next-review/creaturebar-frame-fixed-comparison.svg`.

No staging, commits or pushes were performed.
All fixture hosts and matching test-profile browser processes were closed;
the final process check found none remaining. The initialized Ruby shell is
retained for subsequent work.
