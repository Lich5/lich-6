# CI foundation traceability

Implements `SPEC-CI-FOUNDATION` 1.5.0. REQ-CI-002 and REQ-CI-020 remain intentionally red forward acceptance gates until the core GTK migration is complete. REQ-CI-001 and REQ-CI-061 await confirmation from a published GitHub run. The branch-protection portions of REQ-CI-013 and REQ-CI-051 are owner-only.

| Requirement | Implementation | Validation / observable |
| --- | --- | --- |
| REQ-CI-001 | CI foundation workflow | pinned `ruby/setup-ruby` installs `.ruby-version`; every Ruby job logs its interpreter path and exact version |
| REQ-CI-002 | CI foundation `without-gtk3` matrix | GTK-free bundle and suite |
| REQ-CI-003 | CI foundation `with-gtk3` matrix | GTK-present bundle and suite |
| REQ-CI-010 | `lib/common/script_scope/gtk/.gitkeep` | directory has no Ruby implementation |
| REQ-CI-011 | `check_shim_namespace.rb` | checker scans Ruby sources outside shim |
| REQ-CI-012 | `ci_foundation_scripts_spec.rb` | planted namespace reference fails checker |
| REQ-CI-013 | CI foundation workflow | boundary checker exits nonzero on violation; required-check configuration remains owner-only |
| REQ-CI-020 | `startup_load_check.rb`, `startup_probe.rb` | four real entrypoint subprocess modes with deterministic local startup dependencies; default startup remains red on the core GTK load |
| REQ-CI-021 | `startup_load_check.rb` | per-mode logs, result records, derived loaded-feature lists, and an aggregate summary are uploaded |
| REQ-CI-030 | `conformance_harness.rb` | fixture trace returns shaped result |
| REQ-CI-031 | `conformance_harness.rb` | binary verdict and failure category field |
| REQ-CI-032 | `spec/fixtures/conformance/manifest.yml` | fixture provenance manifest |
| REQ-CI-050 | custom RuboCop ASCII cop | planted non-ASCII source fails |
| REQ-CI-051 | CI foundation RuboCop job | inherited configuration runs; required-check configuration remains owner-only |
| REQ-CI-060 | security manifest | exactly ten required pending entries |
| REQ-CI-061 | security registration workflow | twenty check runs target the push SHA or pull-request head SHA; live publication awaits owner publication |
| REQ-CI-062 | bulk-leakage manifest entry | canary and four sinks specified |
