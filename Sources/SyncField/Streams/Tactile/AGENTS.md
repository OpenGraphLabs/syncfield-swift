# Tactile / Wrist-IMU streams — agent notes

## ⚠️ Wire protocol is a firmware↔parser contract. Keep it in lockstep.

The OGLO glove packs **taxels + wrist IMU into one BLE notify packet**. The host
supports a **single** wire format — schema_ver 5, `packed12_v5` (FW ≥ 0.7.0,
golden `0.7.1-cfgfit`). A skew here fails *silently*: taxels misparse or the IMU
drops to 0 frames, and the empty `wrist_imu_<side>.jsonl` only surfaces downstream
(upload stuck / empty column). `TactileBLEClient` rejects any `schema_ver != 5` at
connect (`Error.unsupportedSchema`) so a mismatched glove fails loudly, not quietly.

### schema_ver 5 (packed12_v5) layout

Header (10B): `[count:u8][flags:u8(0x04)][seq_base:u32le][t_base_us:u32le]`, then
`count` sample slots.

Per-sample slot (stride 134B for 80 taxels):

| offset | type        | field         | meaning |
|--------|-------------|---------------|---------|
| +0     | u16le       | `dt_us`       | `t_us[i] − t_base_us` (sample 0 = 0) |
| +2     | 120 B       | `taxels`      | 80 × 12-bit, packed 2-per-3-bytes |
| +122   | 6 × i16le   | `imu_raw`     | `ax,ay,az,gx,gy,gz` (raw LSB, no fusion) |

12-bit unpack (triplet `b0,b1,b2`): `even=(b0<<4)|(b1>>4)`, `odd=((b1&0x0F)<<8)|b2`.

Per-sample device timestamp is **real**: `device_ts = t_base_us + dt_us` (do NOT
synthesise a cadence). The IMU is raw 6-axis only — no `roll_cdeg/pitch_cdeg/ok`.

Firmware source of truth: `oglo-hardware/firmware/OGLO-MT-RDR-02/oglo_rdr02_ble/oglo_rdr02_ble.ino`
(`BLE_FLAG_PACKED`, `packTaxels12`, `putImuRaw`, `PKD_SAMPLE_STRIDE`) and
`oglo-hardware/firmware/OGLO-MT-RDR-02/BLE_PACKET_FORMAT_v5.md`.

## Rules when editing `parseV5` / `handlePacket`

1. **Taxels first, IMU best-effort.** Parse the full taxel payload (dt_us + packed
   taxels) for every sample before touching IMU. A truncated trailing IMU block must
   NEVER drop taxels (`taxelExpected` gates taxels only; each IMU is decoded only if
   its 12 bytes are present, else `imu[i] = nil`).
2. **Real timestamps.** Emit `device_ts = (t_base_us + dt_us) × 1000` ns per sample;
   `capture_ns = arrival_ns + dt_us × 1000`. Never reconstruct from `rate_hz`.
3. **Wire change = update `parseV5` + `TactileStream.handlePacket` + tests together**,
   in the same change. `flags` without bit2 (0x04) set throws `unsupportedFraming`.

Tests: `Tests/SyncFieldTests/TactilePacketParserV5Tests.swift` — cover the packed-12
round-trip, a realistic 412B packet, real per-sample timestamps, a truncated-IMU case
that asserts taxels survive, and rejection of a non-0x04 framing.
