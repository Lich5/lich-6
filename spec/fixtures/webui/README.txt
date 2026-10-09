Unchanged ecleanse setup fixture

`ecleanse_setup.lic` is the exact `Ecleanse::Setup` module at lines 267–623 of
[`scripts/ecleanse.lic` at 7fd0b971387492cfd81b4bc7ef94428413965071](https://github.com/elanthia-online/scripts/blob/7fd0b971387492cfd81b4bc7ef94428413965071/scripts/ecleanse.lic).
It includes the complete XML and original settings, change, Close and destroy
handlers. Do not simplify the XML or rewrite callbacks to accommodate the shim.

Provenance checks:

- Original whole-script SHA-256: `64e7b1d920bed944b8b33bf9a192c13bb23289d932e6873f38d61579971da4bf`.
- `Setup.ui` SHA-256: `1dec1310d30d6b3f1e34beb7a39aeccdffdd6da70e87c476818759405be13eea` (25,513 bytes).
- The Builder regression asserts the XML digest and 54 constructed objects.

The RSpec harness supplies inert game lookups, a temporary settings directory and
message capture; it does not execute the script's game loop. Unit tests exercise
initialization, changes and close lifecycle. The explicit Chrome run drives the
same controls and original callbacks through the production WebUI transport.
Passing these tests demonstrates setup support, not whole-script gameplay or
native desktop-window parity.
