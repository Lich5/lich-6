WebUI setup fixture provenance and acceptance boundaries

This record describes frozen fixtures, not the latest upstream script versions.
There are ten script fixtures: eight unchanged positive setup candidates and
two unchanged negative candidates (eloot and Bigshot), also exercised with
explicit test-only source repairs. These ten fixtures are not a total-corpus
compatibility count. See docs/webui-review-readiness.md for the current handoff.

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
initialization must report BuilderError even with nil suppression present.
Unhandled queued Builder failures close the owner's UI and request the existing
asynchronous script stop. No widget is fabricated.

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

Repository's basic Ruby case receives two inert listing records. Additional
cases supply long comments and enough synthetic rows to overflow the viewport.
Its original download handler is captured at Script.run, so no download occurs.
Tests verify numeric model sorting,
filtering, single-click activation, command construction and Close/cleanup.
Go2 receives inert GS/DR character data and an in-memory Go2.load destination.
Go2's GS and DR layouts run original setup, updates and Close/destroy callbacks in
Ruby and independent Chrome cases; repository has its own GS case.
No travel, repository network operation or gameplay
loop executes. Converted WebUI counterparts informed acceptance behavior only;
no converted business logic or script-name rendering cases enter the shim.

Unchanged bigshot and huntplan setup fixtures

These retain exact Setup class excerpts with enclosing module wrappers. Original
XML, construction and callbacks are digest-checked before execution. The two
fixtures preserve upstream formatting; RuboCop Layout exclusions and Huntplan's
unused local exclusion apply only to these excerpts, not product or harness code.

- bigshot: frozen EO original, lines 1300-2704;
  class da564437b0eb893e8abd3757afdbbe35bd57b4b134d24e562e4f17d1af76ad34;
  whole script f96ac381aa1f09f248f79de486bf236fa4ae558d3231ad90941333dd4e3f2873.
- huntplan: retained original, lines 1992-2112;
  class 14d3be8481c1d1abc76cf7394c9dc7d7fb4aca8966b33fb4d3940f9bcabf92a5;
  whole script 37a6af449da8f8bbf26cc63d8b714d52099c87fe994dabeddeac6f07a5fbd726.

Huntplan's original setup, input limits, invalid-slot refusal, Save & Exit and
cleanup run in Ruby and Chrome with inert game data and in-memory persistence.
Bigshot's retained original source fails on the undeclared boon_flee_from
tooltip target before connecting its XML signals. This is an expected source
failure, not successful Bigshot acceptance. Its converted version was inspected
as a behavior reference; converted business logic is not copied into the shim.

Explicitly corrected eloot/Bigshot acceptance candidates

webui_builder_source_repairs.rb applies exact-match substitutions only while
loading separately labeled positive tests. Fixture files remain untouched.
eloot names its existing Exclusions label exclusions_label; Bigshot removes
the obsolete tooltip assignment and replaces its legacy boon-flag migration.
Source digests are checked before these substitutions. The unchanged negative
tests remain mandatory, so candidate success does not hide production defects.

Corrected eloot exercises all twelve list add/delete handlers, scalar entry/spin
settings, tipping-preview dispatch with isolated calculation/formatting, dependent
controls, Close/save and destroy without save. Corrected Bigshot exercises scalar
and text-area callbacks, boon selection/migration, profile load/new/overwrite/
cancel/update, Close/save and destroy without save. Both also run in Chrome.
This establishes setup/UI acceptance for those explicit repairs, not live-game
behavior or proof that an upstream author has adopted the same repairs.
