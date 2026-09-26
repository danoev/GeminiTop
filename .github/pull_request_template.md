# Summary

Describe what this PR changes and why.

---

# Engineering objective

What specific problem or research objective does this PR address?

Avoid combining unrelated refactoring with functional changes unless necessary.

---

# Target scope

Which target(s) does this apply to?

- [ ] Generic Gemini/S7-QA
- [ ] Audi reference
- [ ] Mercedes reference
- [ ] W176 / NTG5 development target
- [ ] Another target: __________________

---

# Evidence

What evidence supports this change?

Classify the relevant conclusions:

- **CONFIRMED:**  
- **REFERENCE ONLY:**  
- **INFERENCE:**  
- **UNKNOWN:**  

Do not promote reference behaviour to target fact without evidence.

---

# Changes

List the meaningful changes.

- 
- 
- 

---

# Safety impact

Does this PR introduce or alter any of the following?

- [ ] Target-side writes
- [ ] Firmware creation/modification
- [ ] NVM access
- [ ] Raw MTD/block-device access
- [ ] CAN transmission
- [ ] MCU commands
- [ ] Networking
- [ ] SSH/Telnet/Netcat
- [ ] Launcher/service control
- [ ] Boot/update behaviour
- [ ] None of the above

If any safety-sensitive item is checked, explain the exact effect and failure mode:

---

# Tests

List the exact tests/checks run and results.

```text
<commands / results>
```

Where relevant, include failure-path tests as well as happy-path tests.

---

# Proprietary / sensitive data check

Confirm that this PR does **not** add:

- [ ] firmware ZIP/BIN images
- [ ] extracted proprietary filesystems
- [ ] copied firmware executables
- [ ] NVM/userdata captures
- [ ] credentials
- [ ] unnecessary raw probe captures
- [ ] personally identifying information

If any item is intentionally included, explain why and request explicit review.

---

# Physical validation

Does this change require validation on a physical RoadTop unit?

Yes / No

If yes:

**Target:**  

**Required test:**  

**Abort criteria:**  

**Expected safe failure mode:**  

Do not present host-side test success as proof of physical-target compatibility.

---

# Remaining unknowns

List anything this PR intentionally does not establish.

- 
- 

---

# Reviewer notes

Highlight the areas that deserve the closest review.

For safety-sensitive work, keep the PR in draft until the relevant review gate is complete.
