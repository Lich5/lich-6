# Contract 2.17 adoption review

## Conclusion

Nisugi's work contains useful primitives and substantial completion of features
already promised by 2.5. It should be consumed selectively. It is not a reason
to bring the broad GTK shim, Builder, models or Cairo emulation into lich-6.

Incoming focus events are a demonstrated gap in the accepted shim population.
Admitting that narrow capability is the recommended first contract amendment.
No amendment is implemented by this review. Discuss the proposal with Doug
before changing the locked authority, version, schema or runtime event vocabulary.

## Exact subjects

- lich-6 authority: contract 2.5.0, 29 component types; working tree on
  `a25aade03c1087267d8082e798d2ff5c82b46273`.
- lich-5 integration: `19fad8ab1786798c62e96e4b8738dc4508f3920f`.
- PR #1650, `webui/contract-primitives`:
  `4251f279c870c632002c62d0413cd6b951736411`.
- Its actual current contract is **2.19.0**, not 2.17.0.
- The consolidated 2.17 vocabulary is commit
  `a86472e373cf5cb6216bfded737343ff2e86c53f`; renderer completion is `d9dc6436`.
- The isolated PR range starts after `webui/wiring`,
  `eab7a799db9aa04591c209b2f92a4f2f3693d0c2`, and contains 16 commits.

The references to 2.17 in the handoff/rebuild documents describe a snapshot of
many earlier additions. The specific 2.17 increment added geometric shape
layers. The consolidated snapshot also includes changes dating from 2.7 onward.
Semantic exports confirm 29 types in 2.5 and 32 in both 2.17 and 2.19. The three
new types are `nav`, `menu` and `menu_item`. Page facilities are unchanged.

## What is useful, and for which work

| Addition or work | Demonstrated purpose | Recommendation |
|---|---|---|
| Input `focus` / `blur` events | Frozen `alias.lic:151,169,239,257` and `vars.lic:127,145` initialize/edit rows on focus. A server request to move focus does not report incoming focus. | Admit narrowly for measured plain text inputs, after specifying ordering, rerender behavior, viewer isolation and no submission on focus/blur. Add textarea only with a measured consumer. |
| Existing 2.5 renderers | The current lich-6 client has explicit renderers for 18 of the 29 locked types. Eleven still lack renderers: expander, split, overlay, scroll, markdown, log, image, textarea, number_input, slider, composite. Nisugi supplies all 32 current types. | Reuse the missing 2.5 rendering work as each admitted script requires it. This is implementation completion, not a vocabulary expansion. Test each real consumer. |
| Box `grow` / `pad`, grid `weights`, per-side margins | Preserves packing and asymmetric spacing. Frozen scripts use unequal packing and x/y padding; the broader stack also cites Builder layouts. Our partial shim currently approximates some of this. | Consider a small layout amendment against measured plain-widget cases. Do not claim exact packing compatibility before those cases pass. Do not use Builder counts as the shim's acceptance criterion. |
| Scroll offsets, content extent and viewport size | `alias` and `vars` calculate a scroll-to-bottom animation from adjustment values after adding rows. Broader map behavior uses both axes. | Prefer an explicit declarative scroll-to-bottom capability where acceptable; compare it with measured behavior before admitting raw geometry reporting. Existing `scroll_to` targets identifiers and does not reproduce the arithmetic by itself. |
| Text markup and text size | `boon:327` uses a blue bold span; `armor` uses multiple colored/font spans. | Keep semantic emphasis/size separate from arbitrary fonts and colors. Full Pango presentation support reverses a declared 2.5 degradation and needs an explicit architectural choice. Do not import it incidentally through the validator. |
| Navigation list and selectable groups | Provides keyboard/ARIA navigation and selectable cards. No use established in the accepted 29-script shim population. | Defer to a native UI consumer. Useful design vocabulary, but not needed to resolve the current shim gap. Fix the server validation findings below first. |
| Menus, context-menu links, pointer press/release, page keys | Broader GTK/menu/map compatibility. | Evaluate against native map/bigshot designs. A native conversion need not copy each GTK gesture or menu representation. Keep out of the bounded shim unless a measured admitted consumer establishes the need. |
| Table `headers` | Hides headings for model-backed list layouts; the source comments cite eloot. | Defer to native conversion requirements. Model consumers are excluded from this shim. |
| Composite `line`, `rect`, `ellipse` layers, stroke/fill | Represents circles, boxes and crossed lines without rasterization. Existing 2.5 composite has image, label, bar and region layers. | A plausible small extension for native `map.lic`; declarative shapes do not require Cairo or a general canvas API. Consider at conversion design time. |
| Composite click scroll offsets; 2.19 `surface_zoom` | Supports scrolled map coordinates and Ctrl+wheel zoom. | Evaluate with native map tests. Specify coordinate spaces and bounds explicitly. No need to inherit GTK Layout or Pixbuf machinery. |
| 2.18 password `change` notification | Empty notification that typing occurred. Does not provide a password value for a server-side strength calculation. | Defer without a concrete native need. The adjacent submission bug below defeats the intended guarantee in a valid configuration. |
| Exported contract and DOM harness | Detects schema drift and tests real client DOM behavior. | Reuse the approach. Generated JSON is an artifact, not another hand-maintained authority. Extend coverage to the admitted semantics and security negatives. |

The handoff references EOHunter as a native composite consumer. Its cited
`scripts/eohunter/setup/page.rb` is absent from the inspected integration
checkout and frozen conversion snapshot; this review does not claim to have
validated that external consumer.

## Reproduced adoption blockers

### P1: nonterminal events can transmit a password through submission

In lich-5 `lib/webui/assets/app.js:187-189`, `emit` attaches the control's declared
submission scope for every event, not only terminal events. `payload: {}` is
therefore insufficient to promise that a focus or password-change notification
carries no value.

Using the existing jsdom harness and its `edits` fixture, declare a legitimate
Enter/submit scope on a text input (or on the password input itself), including
the password component. Enter a synthetic password. Focusing the text input
sends that password in `submission`; the 2.18 password `change` notification
also sends it. Both event payloads remain empty. No live credentials were used.

The integration server's `lib/webui/runtime.rb:506-510` likewise builds a
submission without requiring a terminal event. The narrow client/schema idea is
salvageable; the current implementation must not be imported wholesale.
The lich-6 work already added terminal-only client submission and corresponding
server refusal. Those protections must survive any selective reuse, with new
focus/blur/password-change regressions if those events are admitted.

### P2: new selections lack corresponding server invariants

`lib/webui/validator.rb:568` checks tab, table and region membership, but lacks
equivalent checks for the new navigation and selectable-group features.
Direct probes of the actual validator accepted all four cases:

- `nav.select` naming an ID absent from `items`;
- `nav.select` naming a disabled item;
- `group.select` when `selectable` is false;
- `menu_item.activate` for a separator.

The browser's click guards do not establish a server guarantee. A bound callback
must not receive invalid domain selections merely because their strings have the
right shape. If these facilities are adopted, add membership/enablement rules,
negative runtime tests and browser accessibility tests.

### Architecture: presentation compatibility is a separate decision

The expanded markup permits font names, font sizes and arbitrary named/hex
colors. It parses an allowlisted vocabulary and constructs DOM nodes, rather
than inserting source HTML; that is valuable implementation discipline.
Nevertheless, it contradicts 2.5's intentional loss of arbitrary fonts/colors
outside composite layers. A safe parser does not itself authorize that wider
support commitment. The same distinction applies to Builder/model/Cairo wrappers:
useful native primitives do not require their legacy emulators.

## Size, fairly attributed

The isolated PR #1650 range changes 35 files, adding 13,949 and removing 129
lines. That is not 13,949 lines of new handwritten runtime logic:

| Category | Added | Removed | Net |
|---|---:|---:|---:|
| Production Ruby/JS/CSS, including comments | 2,503 | 118 | 2,385 |
| Generated contract.json | 8,416 | 0 | 8,416 |
| Specs and fixtures | 2,475 | 11 | 2,464 |
| Package lock | 555 | 0 | 555 |

The 2.17 vocabulary commit alone is +602/-36 across code, specs and fixtures;
the renderer commit is +2,211/-41. Some of that renderer work fills existing
2.5 promises. These figures describe this branch only, not the whole integration
or Nisugi's cumulative contribution. No estimate of duplication follows merely
from these totals.

## Verification and limits

- Exported and compared actual 2.5, 2.17 and 2.19 schema data in separate Ruby
  processes under the owner's interactive `rubystd` Ruby 4.0.5.
- Current lich-5 contract foundation, primitives, validator and export specs:
  **75 examples, zero failures** (seed 46512).
- Current lich-5 DOM harness: **27 tests, zero failures**, using existing Node
  and jsdom. No installation occurred.
- Additional probes reproduced both submission leaks and the four validation
  omissions above. Existing green tests do not cover those negative cases.
- This is a source/schema and focused executable reuse review, not proof of all
  32 types in a live game or every OS/browser combination.
- No lich-5 tracked file changed. No contract was changed in lich-6. No staging,
  commit, push, fetch, dependency installation or PR publication was performed.

## Proposed decision

Approve a narrow contract addendum for the measured incoming focus event first,
including any necessary blur semantics established by its tests. Preserve the
29-type vocabulary and ten-operation adapter port. Keep submission terminal-only
and viewer state isolated. Reuse Nisugi's focus mapping/client event hooks only
after those regressions pass.

Continue completing existing 2.5 renderers and the bounded shim. Bring each
layout/scroll extension back as a concrete measured need. Reserve shapes, zoom,
navigation and menus for the native conversion design discussion. Keep Builder,
models and Cairo/GdkPixbuf emulation outside this shim. This review proposes that
sequence; it does not approve or implement it.
