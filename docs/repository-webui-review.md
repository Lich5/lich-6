# Repository WebUI release review

Status: owner confirmed ready for beta on October 6, 2026. This acceptance
supersedes the remaining-review gates recorded below; the observations remain
as historical context. The assistant did not install an override. Reviewed October 5, 2026
against scripts baseline `7fd0b971387492cfd81b4bc7ef94428413965071` and core
`901733ecac4c433df616212ae1c6c92eb9bc1ca9` plus the working changes below.

## Changes in this review

- `Projects/scripts/scripts/repository.lic`: inherit the core theme instead of
  forcing light; request the original two-direction table grid; use single-line
  cells. Existing conversion and unrelated script changes are preserved.
- With explicit owner approval, the core table accepts optional `wrap: false`.
  The renderer uses CSS natural single-line widths, horizontal scrolling, and
  clipping after manual column resizing. Omitted/true retains existing wrapping.
  No script-name cases, measured column widths, or shim vocabulary were added.
- Core implementation files: `lib/webui/contract.rb`, `lib/webui/assets/app.js`,
  `lib/webui/assets/app.css`. Regression tests:
  `spec/lib/webui/bounded_contract_spec.rb` and
  `spec/webui/webui_table_editor_test.cjs`.

## Checks completed

- Whole-source comparison: everything outside the GUI block and `execute_gui`
  is byte-equivalent to the frozen original. No download, upload, calculation,
  authentication, persistence, or game logic was changed in this review.
- The actual frozen GTK Builder/controller and native controller received the
  same 80 disposable records. Five searches matched all nine display columns
  and four numeric sort values. Comments and the default `Script.run` command
  matched, including `force: true`. The command was intercepted, not executed.
- GUI entrypoint check covers fetch, comment enrichment, and controller start.
  Controller suite: 9 examples, zero failures, one browser-gated example pending;
  separate actual Chrome checks below cover its principal interactions.
- Twelve GTK captures and twelve Chrome captures: light/dark, populated/no-match,
  at 1200×650, 400×300, and 1440×810. These are content comparisons, not OS resize
  evidence. Chrome search, selection, literal long comments, reset and default
  download dispatch passed without browser errors.
- Actual dedicated Chrome app: search submission and selection passed; native
  corner drag changed 1200×650 to 1000×550; OS close and reopen restored size.
  Closing one of two Repository windows left the other able to search.
- The final two-window fixture released both pages, browser profiles and host.
  The first two single-window harnesses exited before browser-monitor cleanup;
  their remaining test profiles were removed after process exit was verified.
  No blank tabs were opened. No owner Chrome processes were terminated.
- Core WebUI and shim specs: 304 examples, zero failures, two existing gated
  browser examples. Renderer suites: 77 passed. Focused RuboCop: two Ruby files,
  no offenses. Script syntax and both relevant `git diff --check` runs passed.
- Failing-before checks reproduced forced-light behavior and the missing
  single-line table option; both passed after correction. No new Ruby methods
  were introduced; the contract option and CSS behavior are documented inline.

Local disposable comparison harnesses, logs, JSON and screenshots are under
`/private/tmp/repository-review`; they are not dependencies of the core suite.

## Required owner review / remaining gaps

- Paint is close, not pixel-equivalent: Chrome grid lines are dotted versus the
  GTK theme's faint lines; column padding, some header widths and top offsets
  differ; search lacks GTK's magnifier; the comments pane lacks its GTK inset
  border. The original also exposes its nominally hidden link-data label after
  `show_all`; the existing conversion omits that visual wart.
- Exact position restoration is unaccepted: the first window reported [22,52],
  while reopening reported [15,37]. Size restoration passed. GTK keep-above is
  not reproduced. OS minimum sizing and scroll gestures still need review.
- One native automation typing attempt entered only `sc` from `script012`;
  accessibility value assignment plus Enter and browser fill succeeded. This
  does not establish whether typing loss is automation or renderer behavior;
  normal live typing remains a required check.
- Test a real repository listing and a deliberately chosen download on login,
  including rapid search, header sorting, column resize, scrolling and close.
  Fixtures did not contact the repository service or modify installed scripts.
- Installation requires the checkpoint-1 differences to be corrected or
  explicitly accepted. The converted script now requires the approved table
  option in core; an older build will reject that property.

Final installation inspection found a regular file at
`/Users/doug/lich-5/scripts/custom/repository.lic`, timestamped October 5 at
21:23 local time, matching the current conversion SHA-256
`dd50e1423806077fc7f326564e4e6f9946c0ae308ed5d14310a9a2f14d7afb9b`.
It was not written by this review and was left untouched. Its presence does not
close the acceptance gaps above. Custom-root resolution precedes the ordinary
installed script.

No staging, commits or pushes were performed.
