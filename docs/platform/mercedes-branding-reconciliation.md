# Mercedes-Benz branding reconciliation

Historical source commit:
`064dd2ac0bbfaab7738eb84dc93f5e7a50d67c0b` on
`docs/mercedes-branding`.

The commit was reviewed change-by-change after the W176 Stage-1/2/3 evidence
work. Its old file snapshots were not merged over newer documentation.

## Retained intent

- `README.md`: Mercedes-Benz-focused fork wording, W176 + NTG5*1 as the first
  reference implementation, independent evidence for other targets, and the
  Mercedes compatibility-layer direction.
- `ROADMAP.md`: explicit first-reference-target scope and no implied support for
  other Mercedes-Benz installations.
- `AGENTS.md`: the same compatibility boundary is part of agent instructions.
- `CONTRIBUTING.md`: other Mercedes targets are welcome as evidence but do not
  establish compatibility; the architecture is a compatibility layer.
- `.github/ISSUE_TEMPLATE/bug-report.md` and `hardware-report.md`: consistent
  Mercedes-Benz wording; the hardware template now refers to any physical
  probe rather than only the completed Stage-1 milestone.
- `docs/platform/firmware-safety.md`: legacy fixed-layout tooling is excluded
  from the whole Mercedes-Benz platform workflow.
- `docs/platform/target-assumptions.md`: Audi branding is not a Mercedes-Benz
  target default.
- `docs/workstreams/w176-platform.md`: the workstream is a Mercedes-Benz
  platform effort beginning with, but not generalised from, W176.
- `firmware_tools/README.md`: legacy tools remain outside the Mercedes-Benz
  platform workflow.

## Intentionally not copied verbatim

- Older Stage-1-era status and roadmap text was replaced by current completed
  Stage-1/2/3 evidence and Stage-4 planning.
- The older README title's word `Engineering` was not retained because the
  shorter fork title carries the same scope and matches the branding commit.
- `Stage-1 probe result` in the hardware issue subtitle was generalised to
  `physical probe result` so the template remains correct after Stage 1.

No meaningful project-scope or compatibility intent from the historical commit
remains exclusive to `docs/mercedes-branding`.
