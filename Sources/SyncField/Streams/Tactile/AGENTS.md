# Tactile / Wrist-IMU streams — agent notes

## ⚠️ Wire protocol is a firmware↔parser contract. Keep it in lockstep.

The OGLO glove packs **taxels + wrist IMU into one BLE notify packet**. The
on-wire framing is decided by the firmware per-packet via `header[1]` (flags),
and `parseV4` MUST accept every framing the firmware can emit. A skew here fails
*silently*: taxels keep parsing, IMU drops to 0 frames, and the 0-byte
`wrist_imu_<side>.jsonl` only surfaces downstream (upload stuck / empty column).

schema_ver >= 4 header: `[count:u8][flags:u8][base_ts_us:u32le]` then `count` samples.

| flag | framing | sample slot | IMU location |
|------|---------|-------------|--------------|
| `0x01` bit0 — Method B | per-sample IMU | taxels + 17B IMU | each sample |
| `0x02` bit1 — Method C (FW ≥ 0.6.5, 2026-06-16) | packet-level IMU | taxels only | ONE 17B block after all samples |

IMU block (17B): `roll_cdeg,pitch_cdeg,ax,ay,az,gx,gy,gz` (8×i16le) + `ok`(u8).
Firmware source of truth: `oglo-hardware/firmware/OGLO-MT-RDR-02/oglo_rdr02_ble/oglo_rdr02_ble.ino`
(`BLE_FLAG_IMU`, `BLE_FLAG_PACKET_IMU`, `appendBleSample`, `putImuBlock`).

## Rules when editing `parseV4` / `handlePacket`

1. **Taxels first, IMU best-effort.** Parse the full taxel payload before touching
   IMU. A truncated/absent IMU block must NEVER drop taxels. (`taxelExpected` guard
   gates taxels only; the packet-level IMU is decoded only if its bytes are present.)
2. **Accept all firmware framings.** Adding a new flag = update `parseV4` +
   `TactileStream.handlePacket` + tests together, in the same change.
3. **Method C = one IMU sample per notify packet** (not per taxel sample) →
   wrist-IMU rate = taxel_rate / batch_size. Emit one `wristImuSibling.append`
   per packet, aligned to the batch's first sample timestamp.
4. Method B and C are mutually exclusive on the wire; never assume one.

Tests: `Tests/SyncFieldTests/TactilePacketParserV4Tests.swift` — cover every
framing + a truncated-IMU case that asserts taxels survive.
