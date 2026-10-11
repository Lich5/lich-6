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

Unchanged ewaggle setup fixture

`ewaggle_setup.lic` is the exact setup section (lines 199–634) of the retained
original GTK script, including Builder XML, original initialization, signals,
list-transfer handlers and save/destroy behavior. No callbacks were rewritten.
Whole-script SHA-256: fe74b93bbc73ce83981ff8e23dba11dcc0e51a905454685afb39988eb87726e4.
Setup.ewaggle_ui SHA-256: c617157ee342adb4bfcb9d3281de5d63c17ef777d4f75fcad60544ec6049eddf
(28,928 bytes; 77 constructed objects).
The harness substitutes game lookups and Ewaggle.save_profile's destination only.
Chrome exercises prefix search, cross-list drag/drop, same-list duplication,
named ComboBox selection, numeric edits and the original Close callback.
Ruby also verifies destruction without saving and unsupported input refusal.
These checks establish setup behavior, not casting-loop or whole-script acceptance.

Unchanged ebounty, eherbs, eloot and BlackArts setup fixtures

These retain the original Setup classes from the same frozen EO script tree
(7fd0b971387492cfd81b4bc7ef94428413965071), with only enclosing module/GTK-guard
wrappers needed for isolated loading. XML, initialization and callbacks are not
rewritten. The retained class line ranges and SHA-256 values are:

- ebounty: lines 1151–2033; class ea8e307083274d54569f48364fd1add9dcf41f1069733b77162136fe67db08c3;
  whole script 9cb9dafe5941f8336a51006846b0c86b712cca2b2340ea1e1c042e7ede781ab7; 435 objects.
- eherbs: lines 525–823; class 154a35392391da1a7869545ec3afbac170c3f3c2660a537570138d1ab2802535;
  whole script 6feecbcec73718d8127432187f3453e06020ba52dc5f312efd4e9dcac5fe5083; 31 objects.
- eloot: lines 720–1926; class 903ec1942b966626de0644d2c2ade7d5e4e5f02e7fd743bd7306aa7492f34077;
  whole script 1e1d5c5bc5e845f47821d1fe0b676b08cdbd139e83f8c594ff221e6cc707a349; 469 objects.
- BlackArts: lines 5282–6045; class 2d76eedd2e65a8bc6546e07fc0f84610cf2d4b8c9171edabbebce4c357e9526c;
  whole script 15932bdd0fa9efcd0a4a13222ebbc3032dda22db8ab28c3effd542349c828703; 216 objects.

The harness substitutes only game catalogs, character availability, profile
discovery, message capture and persistence destinations. ebounty/eherbs/BlackArts
each have independent browser examples and original Close/destroy checks.
ebounty/BlackArts retain source uniq!.sort! chains; subprocess tests load Lich's
actual NilClass extension without changing the parent RSpec process. Removing
that production extension will require source migration; it is not shim support.
eloot is a negative fixture: its XML never declares exclusions_label, so tooltip
initialization must report BuilderError even with nil suppression present. The
recommended disposition is native WebUI conversion, not a fabricated widget.

The preserved native WebUI versions of all three positive fixtures were reviewed
for reusable behavior. Their settings and script-specific form code remain out
of the shim. These tests do not execute game loops, certify all settings paths,
or assert native desktop-window/pixel parity.

Unchanged repository and go2 setup fixtures

These retain the complete Setup classes from the same frozen EO source tree,
including original XML, initialization, filtering/settings callbacks and Close.
Only enclosing module/class/GTK-guard wrappers are supplied for isolated loading.
Class hashes exclude wrappers and the trailing newline and are checked in RSpec.

- repository: lines 880–1042; class ac0107e3149a487f61cfd345a3b962b7673df65ec99921f4b9fdd74d47dd86e5;
  whole script d46a023aaac5f96c1395b89727d0640cee69a91a9103853353de3a1389fe1aa0.
- go2: lines 474–842; class 8bdcf8959473c59d9da2eba4dbc69a2dd13185acd9a3c556288b1bd8198862b2;
  whole script e4763e1fd11ee2645409067dd5ed3463d7e6f8fd48595ae01b19d4aea04237a6.

Repository receives two inert listing records; its original download handler is
captured at Script.run, so no download occurs. Tests verify numeric model sorting,
filtering, single-click activation, command construction and Close/cleanup.
Go2 receives inert GS/DR character data and an in-memory Go2.load destination.
Both game layouts run original setup, updates and Close/destroy callbacks in Ruby
and independent Chrome cases. No travel, repository network operation or gameplay
loop executes. Converted WebUI counterparts informed acceptance behavior only;
no converted business logic or script-name rendering cases enter the shim.
