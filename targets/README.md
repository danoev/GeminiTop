# Target profiles

Profiles are evidence records, not compatibility promises. Each fact has a
state:

- `CONFIRMED`: observed on the named physical target.
- `REFERENCE_ONLY`: observed in a different unit or reference firmware.
- `INFERENCE`: reasoned from code or indirect evidence.
- `UNKNOWN`: not established.

Runtime code does not consume these profiles yet. In particular,
`w176-ntg5/profile.json` cannot enable a launcher, networking, audio, CAN, MCU,
or illumination behavior.

`match` contains only fields that the host-side identification tool may compare.
Reference matches describe similarity to evidence; they never prove a board
marketing identifier such as QD507.
