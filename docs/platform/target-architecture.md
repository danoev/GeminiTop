# Target architecture

The profile system is deliberately data-only. A target directory contains one
`profile.json` with provenance, evidence-state facts, and a small `match` map
for host-side comparison.

```text
targets/
  audi-reference/profile.json
  mercedes-reference/profile.json
  w176-ntg5/profile.json
```

The Audi and Mercedes directories are reference profiles. The W176 profile is a
physical target profile and starts with UNKNOWN hardware facts. The two version
strings read from the installed UI are CONFIRMED owner observations; they do not
establish board family, partitioning, ABI, display, input, audio, or vehicle-bus
compatibility.

Profiles are not loaded by the launcher or orchestrator. This prevents a
reference value from silently becoming a runtime W176 default. Future runtime
wiring must require a reviewed, authoritative W176 profile and explicit safety
approval.

The host-side comparator treats every field independently and returns only
`MATCH`, `DIFFERENT`, or `UNKNOWN`. A reference `MATCH` means the observed fields
look the same; it is not a board-ID assertion.
