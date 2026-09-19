# Native typography fit decision

Doug authorized assessment and implementation when fit is high on 2026-09-18.
Capability fit is high; the full Pango compatibility parser is a larger change
than these native consumers need. Adopt a bounded native subset as contract
2.7.0, leaving the script compatibility namespace unchanged.

## Evidence and reuse

Nisugi's lich-5 contract 2.19 includes text markup, identified there as a 2.7
addition, with a validator and browser renderer. Its renderer assigns individual
DOM style properties rather than inserting source HTML. Reuse that rendering
approach, not its markup language or font-description parser.

Existing consumers include Creaturebar's name/HP/status settings and its
calibration preview. Bigshot's setup warnings, BlackArts' item-marking warning
and Eloot's warning label also specify foreground colors. This is observed
native-script presentation, not a speculative shim requirement.

## Contract

- Existing `text` components and composite `label` layers gain optional
  `font_size` (finite points, 6..48), `foreground` (structured RGBA) and
  `background` (structured RGBA).
- Existing emphasis supplies normal/bold presentation. Explicit foreground
  overrides semantic tone for that text only; absent properties preserve current
  browser styling. Font sizes use points to match the scripts' persisted units.
- No markup, raw CSS, font-description language, network fonts or HTML is
  accepted. Text remains literal. Color channels retain the existing 0..255 and
  alpha 0..1 bounds. Unknown properties and invalid values fail validation.
- The vocabulary stays at 29 types and the adapter stays at ten operations.
  GTK font/color methods do not begin forwarding these properties. Previously
  accepted shim styling degradation remains unchanged.

## Acceptance

Write validation and DOM specs before implementation. Check literal hostile-looking
text, style bounds, foreground precedence, composite-label parity and unchanged
shim output. Then exercise configured typography in the native calibration
browser fixture. Preserve existing configuration values and remove misleading
stored-only controls once their behavior is implemented.
