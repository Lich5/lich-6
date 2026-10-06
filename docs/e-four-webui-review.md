# EBounty, Ecleanse, EHerbs and ELoot review

October 6, 2026. Functional group pass completed; visual and live-use acceptance
remains open. Reference: Projects/scripts commit
`7fd0b971387492cfd81b4bc7ef94428413965071`.

## Source changes in this pass

| Script | Change |
| --- | --- |
| ebounty.lic | Existing setup footer; four single-line list tables; original sorted profile-file filtering and stored profile text restored |
| ecleanse.lic | Existing setup footer, retaining its notice, margins and Close callback |
| eherbs.lic | Existing setup footer, retaining its notice, margins and Close callback |
| eloot.lic | Existing setup footer; twelve single-line list tables; five intentional blank GTK frame labels retained using nonbreaking spaces |

All four consume the existing `setup_footer` abstraction. No new abstraction,
core library change, game calculation, default, or persistence rule was added.
Existing working-tree core changes predate this pass. Script edits are confined
to `Projects/scripts/scripts/{ebounty,ecleanse,eherbs,eloot}.lic`.

## Checks performed

- Reused the existing controller and frozen non-UI source comparisons:
  **37 examples, zero failures, four gated browser examples pending** (seed 2524).
  Coverage includes defaults, eligibility, exclusive checkboxes, list mutations,
  scroll parsing, cancellation and save/failure ordering. Focused assertions
  failed before the profile, single-line table and blank-label corrections.
- All four scripts pass Ruby syntax and scoped whitespace checks. Ruby 4.0.5
  used through the initialized host interactive zsh session.
- Actual frozen GTK setup classes rendered all tabs with disposable settings;
  natural/smaller/larger allocations and dark initial views were captured.
- Actual converted setup classes opened through the production Chrome app-window
  launcher. EHerbs stock editing and Close, Ecleanse stop-script editing and Close,
  EBounty checkbox/profile/list actions and Close, and ELoot locksmith enablement,
  scroll addition and Close produced the expected disposable settings.
- EBounty and ELoot tabs were visited; both also rendered in dark mode. The final
  EBounty Profiles view displayed the stored `warrior` value. OS zoom expanded
  that real app window from a 1700×1634 to a 5120×2630 pixel capture, with fields
  expanding and the footer remaining at the bottom. These are Retina captures,
  not prescribed script dimensions.
- ELoot was closed with the OS close control and reopened in a fresh fixture;
  the subsequent Close action saved its settings. Final EBounty OS close also
  returned from setup and stopped its host. Test fixture Ruby processes exited.

GTK allocations (logical pixels) were:

| Script | Natural | Smaller request result | Larger |
| --- | --- | --- | --- |
| eherbs | 656×425 | 650×375 | 856×525 |
| ecleanse | 656×675 | 650×675 | 856×775 |
| ebounty | 850×785 | 850×775 | 1050×885 |
| eloot | 900×830 | 900×640 | 1100×930 |

## Remaining acceptance

- Review actual in-game setup with the owner's populated settings, including
  save/reopen and disabled controls appropriate to that character.
- Finish matched empty/populated native comparisons at smaller and larger sizes,
  including minimum sizing, scrolling, and residual typography/popup colors.
  EHerbs/Ecleanse native dark views were not independently repeated in this pass.
- Verify script-specific saved OS size/position restoration and independent-window
  cleanup. The disposable service did not use a geometry store; reopening it
  cannot prove persistence. An attempted ELoot menu resize was not verified and
  is not counted as a pass. EBounty zoom alone does not close the group requirement.

These gaps are unperformed acceptance checks, not a claim that Chrome cannot
perform them. Intermittent stale accessibility state/captures complicated tab
capture; screenshots showing the preceding tab were excluded as evidence.

## Preserved quirks and fixture boundaries

EBounty/ELoot retain the original `uniq!.sort!` failure: a list can mutate before
the callback raises, leaving stale display until refresh. Original footer notices
are retained even where their wording suggests automatic saving.

The fixtures run the real Setup classes and default callbacks, with fake external
character/spell/map hosts and disposable profiles. They do not run a game session.
Frozen ELoot references a missing GTK tooltip label; only the reference fixture
catches that specific nil-widget tooltip failure to allow visual inspection.
No production non-UI logic was repaired for it.

Temporary fixtures, before-edit snapshots, captures and test output are in
`/private/tmp/e-four-review` on the review host. They were reused rather than
adding another permanent test framework. No installed scripts changed. No staging,
commit or push was performed. No additional scope exception was used.
