# CSS decoration measurements and acceptance

2026-10-12, PR 2 on `feat/webui-css-decoration-fallback`, continuing from the
owner's `947a9fdcca7ba879ff3d18309d97e4827d8585c6` commit. No product behavior or
input limit changed in this final evidence slice.

## Scope and measurement decision

The [cached audit](webui-css-decoration-audit.json) supplies the cohort, revisions
and expected source hashes. All **33 source hashes matched** the pinned Git blobs:
EO `7fd0b971387492cfd81b4bc7ef94428413965071` and mirror
`549e33506e121453e3c01cfe5df46a902f44fc5f`. No discovery scan of other scripts,
converted working files, or EO PRs was performed. The two native-conversion
originals and spellson remain comparison cases; the remaining exposure subset
is the same **30 scripts** as the audit.

The retained [fixture](../spec/fixtures/webui/css-decoration.json) contains source
hashes, paths, line ranges, raw call shapes, decoded CSS, substitutions, lengths,
payload hashes, and reviewed executable excerpts. Prism decodes string nodes;
the extraction tool never evaluates source Ruby. **71 payloads cover all 66
provider load sites** (46 keyword `load`, 20 positional `load_from_data`). There
are 29 exact literals and 42 formatted/interpolated/assembled samples. The count
differs from the older focused audit because it covers the full cached cohort.

**Keep the 8,192-character bound.** No extracted literal or constructed sample
exceeds it. The largest exact literal is tpick's **4,742** characters; the largest
constructed payload is stormsync's source-default 152-color grid, **6,230**.
Ten scripts have entirely literal inputs. Others depend on settings, colors,
paths, generated lists or interpolation. Diagnostic substitutions are recorded,
not silently treated as script defaults. Stormsync's default grid and grinsawl's
five fixed tiers are assembled from the pinned source data; custom stormsync
settings can replace the color list.

These measurements are **not a universal runtime maximum**. User-controlled
strings/lists can exceed the bound and will still refuse explicitly. Increasing
the bound would require a measured real input and a separate bounded decision;
there is no evidence here requiring such a change.

## Per-script disposition

Each row reports the largest retained payload. “Sample” denotes at least one
nonliteral input, with all substitutions retained. “Native reference” means the
original GTK source of an already converted candidate, not a new conversion.
Every payload in every row was passed through the actual shim loader. Only
spellson and staminabar2 retain recognized progress styling; other CSS is omitted
with one notice per owner/session. Loaded source CSS is not retained or forwarded.

**No whole original setup or game loop was executed or rendered for these rows.**
All other non-CSS blockers are unknown unless explicitly identified below.

| Script | Cohort role | Maximum characters | Measurement | CSS result |
| --- | --- | ---: | --- | --- |
| Combatical | Remaining exposure | 2,690 | Sample | Omitted |
| UberBarWiz | Remaining exposure | 180 | Literal | Omitted |
| as_audit | Remaining exposure | 195 | Sample | Omitted |
| bug-catcher | Remaining exposure | 2,708 | Literal | Omitted |
| calibrate_creaturebar | Native reference | 2,782 | Sample | Omitted |
| creaturebar | Native reference | 501 | Sample | Omitted |
| creaturewindow | Remaining exposure | 1,839 | Sample | Omitted |
| exitwindow | Remaining exposure | 1,495 | Sample | Omitted |
| gemstone-tracker | Remaining exposure | 1,495 | Literal | Omitted |
| gemstonev | Remaining exposure | 1,052 | Sample | Omitted |
| generate-gemstone | Remaining exposure | 750 | Literal | Omitted |
| grids | Remaining exposure | 516 | Sample | Omitted |
| grinsawl | Remaining exposure | 449 | Fixed assembly | Omitted |
| gshunting4all | Remaining exposure | 122 | Literal | Omitted |
| hazardwindow | Remaining exposure | 795 | Sample | Omitted |
| jastev | Remaining exposure | 98 | Sample | Omitted |
| manatimer | Remaining exposure | 210 | Sample | Omitted |
| manatimer-gtk3 | Remaining exposure | 226 | Format sample | Omitted |
| merchantical | Remaining exposure | 4,796 | Sample | Omitted |
| mission-gemstone | Remaining exposure | 59 | Literal | Omitted |
| nautical-charts | Remaining exposure | 39 | Sample | Omitted |
| panelcontrol | Remaining exposure | 1,937 | Sample | Omitted |
| playerwindow | Remaining exposure | 1,801 | Sample | Omitted |
| rafflewindow | Remaining exposure | 2,429 | Sample | Omitted |
| spellson | Existing progress reference | 231 | Format sample | Recognized |
| staminabar2 | Remaining exposure | 190 | Literal | Recognized |
| stormsync | Remaining exposure | 6,230 | Default assembly/sample | Omitted |
| test-tpick | Remaining exposure | 75 | Literal | Omitted |
| thunder | Remaining exposure | 191 | Sample | Omitted |
| timers | Remaining exposure | 143 | Sample | Omitted |
| tpick | Remaining exposure | 4,742 | Literal | Label foreground cues recognized; other decoration omitted |
| tpick2 | Remaining exposure | 75 | Literal | Omitted |
| treasurewindow | Remaining exposure | 1,211 | Sample | Omitted |

## Source-derived call chains and remaining blockers

The acceptance spec executes narrowly selected, hash-checked CSS-only excerpts
under their original filenames/line numbers. Supported widget objects and fixed
test settings replace game-owned variables; those substitutions are visible in
the spec. It also replays all 81 observed widget/screen attachment signatures:
62 local (30 USER, 20 APPLICATION, 12 omitted priority) and 19 screen (2 USER,
17 APPLICATION). This does not execute the scripts' original setup control flow.

| Source | Excerpt result | Non-CSS/acceptance boundary |
| --- | --- | --- |
| tpick | Global CSS/load/screen registration at 94–291, label-local CSS at 2557–2564 and required-setting class at 2939 continue. First omission is attributed to line 95. | The subsequent HeaderBar slice accepts the original constructor at 2084. Separate tpick welcome/header-method acceptance and expanded default settings/information acceptance are recorded in the handoff; CSS acceptance alone still does not establish complete setup. |
| manatimer | Original 83–94 attaches before load and reloads through both original procs. Fraction survives, CSS fill is omitted. | Actual `Gdk::Display` at 76 still refuses and occurs before these CSS calls. |
| spellson / staminabar2 | Original load/attach excerpts preserve typed color and 24px height, including staminabar2's missing final semicolon. | Full running scripts not exercised. |
| timers | Original generated progress CSS, positional load and attachment continue with fixed test settings. | Custom colors/heights are omitted; fraction is preserved. Full setup not exercised. |
| as_audit | Original typography CSS attaches to supported Window/TextView objects. | Font/color decoration is omitted. TextView typed properties remain unchanged. |
| panelcontrol | Original CSS generator excerpt reloads with two test palettes. | CSS palette/state decoration is omitted. Whole panel setup not exercised. |
| grinsawl | Original five-tier border construction and screen attachment continue without including its blanket rescue. | Foil border decoration is lost; do not describe it as visually equivalent. |
| Combatical | Original global CSS/screen registration and drop-indicator add/remove calls continue. | The drag/drop indicator is omitted. Drag/drop interaction support is not established by these class calls. |
| grids | Original image, radial and linear branches continue as inert CSS with fixed test settings. | Images/gradients are omitted; no referenced image is opened. Whole setup not exercised. |
| stormsync | Original selection-border CSS and no-priority attachment calls continue. The default color-grid payload also loads. | Selection borders/colors are omitted. No excluded Builder setup was opened or expanded. |

Selection borders, drag/drop indicators, typography and palette cues can carry
information. Their omission remains explicit; the later bounded label-color
expansion preserves tpick required-field cues. Fallback is not pixel parity or
proof of equivalent whole-script usability.
Unknown widget/API and invalid Builder-reference hard stops remain. Original eloot
and Bigshot negative acceptance is retained in the full suite.

The Chrome progress fixture additionally loads the retained tpick global and
label-local CSS. It verifies default sibling typography, no DOM class injection,
stable progress identity/fraction and reset/re-recognition. This is a rendered
controlled fixture, **not the original tpick setup** or native OS-window acceptance.

## Reproduction and validation

Use the required retained host interactive zsh initialized with `rubystd`, Ruby
4.0.5. From the lich-6 repository root, set `EO_REPO` to the local EO scripts
checkout path and `MIRROR_REPO` to the local lich_repo_mirror checkout path.
Rebuild from these explicitly authorized read-only source repositories:

```sh
ruby spec/support/build_css_decoration_corpus.rb "$EO_REPO" "$MIRROR_REPO" > "${TMPDIR:-/tmp}/css-decoration-rebuilt.json"
cmp spec/fixtures/webui/css-decoration.json "${TMPDIR:-/tmp}/css-decoration-rebuilt.json"
rspec spec/lib/common/script_scope_css_corpus_spec.rb
NATIVE_BROWSER=1 rspec spec/lib/common/script_scope_widgets_spec.rb --example 'reloads, omits and removes'
```

Routine specs use only the retained fixture; they do not need the source checkouts,
Prism extraction, network access, native GTK, game data or source-script execution.
Validation results are recorded in the [PR tracker](webui-review-readiness.md#css-decoration-work-tracker).

## Subsequent default tpick setup expansion (2026-10-12)

The HeaderBar PR now includes signed Grid origins, empty/live notebooks and a
bounded class-qualified label-color grammar. Required-field labels retain their
source-defined color; unrelated theme CSS remains omitted. The original settings,
profile/default/save and information/message/statistics flows run from hashed
source excerpts. See the current [tracker](webui-review-readiness.md) for validation
and explicit source defects/optional-image limits. Historical CSS-only results
above do not themselves establish this broader setup acceptance.
