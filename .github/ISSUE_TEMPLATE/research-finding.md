---
name: Research finding
about: Submit a reverse-engineering or technical finding for review
title: "[Research] "
labels: research
assignees: ""
---

# Research finding

Use this template for technical findings that may not yet require a code change.

The project values explicit evidence states. Please distinguish direct observations from inference.

---

## Question

What were you trying to establish?

---

## Target / source

What exactly was examined?

Examples:

- installed W176 RoadTop v2.0.61;
- Benz v2.0.65 reference firmware;
- upstream Audi GeminiTop target;
- another specific Mercedes/RoadTop unit.

---

## Evidence

Describe the evidence used.

Examples:

- file paths;
- hashes;
- screenshots;
- static-analysis results;
- probe output;
- physical measurements;
- repeatable behaviour.

Do not upload proprietary firmware bodies or private/raw target data unnecessarily.

---

## Finding

What was directly established?

---

## Evidence state

Choose one:

- CONFIRMED
- REFERENCE ONLY
- INFERENCE
- UNKNOWN

Explain the classification:

---

## What this does NOT prove

List any tempting conclusions that are not justified by the evidence.

Example:

```text
This does not prove the installed W176 unit is QD507.
```

---

## Remaining unknowns

What is still unresolved?

---

## Suggested next test

What is the smallest safe experiment that would resolve the next unknown?

Prefer observation and reversible testing over modification.

---

## Safety considerations

Does the suggested next test involve:

- target writes;
- firmware;
- NVM;
- CAN;
- MCU commands;
- networking;
- Launcher/service changes?

If yes, explain why the test is necessary and what safer alternatives were considered.

---

## Related files / issues / PRs

Add relevant repository paths, issue numbers, PRs, or commit SHAs.
