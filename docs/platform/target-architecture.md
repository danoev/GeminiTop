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
physical installed-target fingerprint. It now contains sanitised facts from the
successful Stage-1 capture as well as the two owner-observed version strings.
Those facts establish the fields explicitly recorded in the profile. Stage-2
also establishes installed `8368_XU` build configuration, startup topology, and
the ELF32 ARM EABI5 hard-float loader boundary. It does not establish a
commercial board family, firmware compatibility, custom-code loadability,
audio routing, or vehicle-bus semantics.

Profiles are not loaded by the launcher or orchestrator. This prevents a
reference value from silently becoming a runtime W176 default. Future runtime
wiring must require a reviewed, authoritative W176 profile and explicit safety
approval.

The host-side comparator first requires the Stage-1 transactional success
contract when reading a capture directory: a complete status with zero
mandatory failures, a regular non-symlink `COMPLETE` marker, and an empty
regular `ERRORS.txt`. It then treats every field independently and returns only
`MATCH`, `DIFFERENT`, or `UNKNOWN`. A reference `MATCH` means the observed fields
look the same; a physical-profile `MATCH` means the capture matches the recorded
installed fingerprint. Neither is a board-ID or firmware-compatibility claim.
