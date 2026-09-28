# W176 Stage-4A physical topology capture — 2026-09-28

The exact frozen candidate `4161bc3b92d61e19751358fb2e210ebfa9c4e8b2`
received independent **GO** and was physically run by the operator. This is
separate from the earlier interrupted attempt, the `owner_limit` fail-closed
attempt with `17557e...`, and the unrun v4 `d0f5d7...` independent NO-GO.
Those historical states remain documented in the earlier attempt and review
records; they are not the result of the successful v5 run.

## Provenance and validation

The operator returned `STATUS.txt` with schema 3, `status=COMPLETE`,
`mandatory_failures=0`, and `optional_findings=1`; a regular `COMPLETE` was
returned and `ERRORS.txt` was empty. The mounted physical
`stage4-topology/` capture was inspected read-only in this repository session.
The analyser source was verified byte-identical to that in the frozen commit.
Rerunning it against the capture returned `capture_validation=PASS` and
`verified_checksums=22`. Its checksum model establishes internal consistency,
not authentication or original FAT inode history.

`SUMMARY.txt` reported schema 4, four interfaces, five device candidates,
120 processes inspected, 302 FD links inspected, two matched owners,
`process_fd_coverage=PARTIAL`, and 501,032 copied library bytes. The sole
optional finding was `process_leader_uninspectable:760:Z`: leader 760 was
zombie/uninspectable. The analyser therefore marked
`ownership_absence_claim=NOT_AVAILABLE`.

## Validated conclusions

- **CONFIRMED for this snapshot:** no Linux ARPHRD_CAN/type-280 interface was
  observed. This does not establish that raw CAN is universally absent or
  unsupported.
- **CONFIRMED positive ownership only:** Launcher (PID/TGID 718,
  `/tmp/sp/application/bin/Launcher`) held FD 19 to `/dev/ttyS4` and FD 24 to
  `/dev/ttyS1`; gocsdk (PID/TGID 772,
  `/tmp/sp/usr/local/bin/gocsdk`) held FD 6 to `/dev/ttyS2`.
- **CONFIRMED in the installed captured library:**
  `libappmcucommunication.so.1.0.0` contains `HcCar`, `HcProtocol`,
  `iLLLightStatus`, `hc_protocol_initialize`, `hc_init`, `hc_mcu_read`,
  `notify_car_event`, `notify_canbox_event`, `/dev/canbox_protocol_dev`,
  `/dev/hc_mcu_dev`, and `/dev/ttyS1`. The copied
  `libappframework.so.1.0.0` has none of those selected strings.
- **INFERENCE:** an MCU/CAN-box translation path before Linux is plausible,
  supported by UART ownership and installed MCU-library vocabulary. Metadata
  does not prove message flow or vehicle-event semantics.
- **Formal classification: CASE D — UNKNOWN.** CASE B is not established by
  this passive capture.

Because process-FD coverage is PARTIAL, no negative owner claim is available:
do not conclude that no other process owns any candidate path. PIDs above
4096 and FD numbers above 127 were not inspected. No device stream was
opened, CAN frame received/transmitted, MCU command sent, or logging enabled.
Only sanitised conclusions are committed; the raw capture and proprietary
libraries remain off Git.
