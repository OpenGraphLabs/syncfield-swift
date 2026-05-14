# Insta360 Go 3S BLE Stabilization — Progress Notes

작성: 2026-05-14

OGSkill (RN) ↔ `syncfield-swift` ↔ Insta360 SDK V1.9.2 흐름에서
양손목 GO 3S 동시 페어링 시 녹화 START 가 간헐 실패하던 이슈에 대한 작업 기록.

---

## 1. 진행한 개선 작업

### 1.1 Wake-free fast path (`Phase 1.1++`)
**파일**: `Sources/SyncFieldInsta360/Insta360Scanner.swift`,
`Sources/SyncFieldInsta360/Insta360BLEController.swift`

세 곳에 "이미 광고 중인 카메라면 wake 생략" 분기 추가:

1. **`Insta360BLEController.pair()`** — Phase A 로 1.5s 짧은 wake-free scan.
   `scanForPairCandidate(requirePoweredOn:)` 에 파라미터 추가하고 호출 시 false 로
   완화 (advertisement 의 `powerOn` 플래그가 첫 packet 에 없을 수 있음).

2. **`Insta360BLEController.reconnectIfNeeded()`** — 동일 패턴. cached identity
   매칭되는 광고를 1.5s 안에 발견하면 wake loop 안 시작하고 바로 `connectScannedDevice`.

3. **`Insta360Scanner.pair()`** — attempt 1 진입 시:
   - 1차: `resolveScannedDevice(identity:)` 로 cache 확인
   - 2차: cache miss 시 `briefWakeFreeScan(matching:timeout:)` 헬퍼로
     1.5s wake-free scan 추가 시도
   - hit 시 `keepWaking` task 미생성

   `briefWakeFreeScan` 은 신규 헬퍼. 발견 device 를 `scannedDevices` 에 등록해서
   downstream `connect()` 의 `resolveScannedDevice` 도 hit 하게 함.

### 1.2 진단 로그 추가
모든 fast path 분기에 결과 로그:
```
[Insta360Scanner.pair] attempt N fastPathCheck: cache=hit|miss scan=hit|miss device=... powerOn=... eligible=true|false
[Insta360BLE.pair] fastPath found ... powerOn=... — skipping wake loop
[Insta360BLE.reconnect] fastPath found ... powerOn=... — skipping wake loop
```

### 1.3 진단 로그 정리 (노이즈 제거)
`SyncFieldBridgeModule.swift` 와 `Insta360BLEController.swift` 에서 성공/정상 경로의
verbose 로그를 제거. 실패/이상 신호와 fast-path 분기 로그만 남김.

대표 제거 항목:
- `[SyncField] emit orientation` (회전마다 출력, 최대 노이즈)
- `[Insta360BLE.gate] acquired/release` (BLE op 마다 2번씩)
- `[Insta360BLE] RSSI/power probe device=...` (refresh attempt 마다, 실패만 남김)
- `[Insta360BLE] WiFi creds from cache/wifiInfo/getOptions/derived` (4개 분기)
- `[Insta360BLE] capture control probe ACK` / `command probe ACK`
- `[Insta360BLE.timing] commandManager ready after pair/reconnect`
  (`Insta360Scanner.timing` 과 중복)
- `[Insta360BLE.wake] Wake auth data written` 등

---

## 2. 현재 상황

### 효과 확인됨
- 양손목 GO 3S 둘 다 ON 상태에서 `assignWristRole` 동시 호출 → fast path
  `cache=hit eligible=true` 양쪽 진입 → wake task 즉시 cancel (`STOP elapsedMs=4`)
  → 후속 `startCapture` ACK (≈2.6s) → **녹화 시작 성공**.
- 이전과 가장 큰 차이는 두 카메라 wake loop 가 중첩 실행되며 bluetoothd 를 stress
  시키던 패턴이 사라진 것.

### 그러나 잔여 신호
같은 성공 케이스 안에서도 다음 신호는 여전히 남아있음:

1. **`XPC connection invalid`** 가 pair 도중 2회 발생. 단 회복 가능한 시점에서
   발생해서 결과적으로 startCapture 까지 도달.
2. **`metadata unavailable; accepting provisionally`** 양쪽 다 발생.
   `assertActionCamHost` 가 device metadata (cameraType/go3Version 등) 를 못 가져왔는데
   "GO 시리즈 광고" 라는 이유로 provisional accept. **거짓 success 의 위험**.
3. **`syncTimeMs timed out (3s)`** 양쪽 다. 페어링 직후 syncTime BLE command 가
   응답 없음 — 채널이 일시적으로 비활성.
4. **페어링 종료 후에도 `[Insta360BLE.wake] ... SEND`** 가 한동안 계속 트리거됨.
   `dockStatus` / heartbeat 의 자동 `ensureCommandReady` 가 `shouldWakeBeforeProbe`
   분기로 들어가 wake 를 또 부르는 것으로 추정.

### Production-readiness 판단
현재는 **운빨이 섞여있는 상태**. fast path 가 wake-induced 손상을 줄여서 회복 가능
범위로 유지된 거지, 채널 자체가 깨끗하게 살아있는 건 아님. 반복 cycle / cold-start
케이스에서 재현 실패율이 어떻게 나오는지 측정 필요.

---

## 3. 남은 작업

권장 순서대로 정리.

### 3.1 반복 안정성 측정 (선행)
- 양손목 페어링 + 녹화 시작/중지 × 20회 cycle
- 단일 손목 cycle × 20회
- 앱 cold start → 페어 / background → foreground → 페어 시나리오
- 각 cycle 의 실패율 및 평균 시간 측정. 실패 패턴이 한 가지로 수렴하면 거기 맞춰
  다음 phase 선택.

### 3.2 Phase 1.4 — Post-pair hello probe
**파일**: `Sources/SyncFieldInsta360/Insta360BLEController.swift`
(`assertActionCamHost`, `pair`, `Insta360Scanner.pair`)

`assertActionCamHost` 의 `.provisionalMetadataUnavailable` 분기를 거짓 success 로
신뢰하지 않게 하기.

- `assertActionCamHost` 통과 직후 1초 timeout 으로 `getOptions(BatteryStatus)` 호출
- ACK 받으면 진짜 ready
- timeout 이면 disconnect + 다음 attempt 로 폴백 (retriable error)
- 이때 던지는 에러는 `notRecordingActionCam` 이 아닌 `commandFailed` —
  Scanner.pair 의 attempt loop 가 재시도하게.

기대 효과: 거짓 success → refreshConnection 시점 timeout 의 chain 차단.
실패가 거기서 더 일찍 가시화되고, 다음 retry 가 깨끗한 BLE 상태에서 다시 시작.

### 3.3 페어 후 자동 wake 트리거 검토
**파일**: `Insta360BLEController.swift` — `ensureCommandReady`,
`shouldWakeBeforeProbe`, `startHeartbeat`, `dockStatus`

페어가 끝난 직후에도 wake 광고가 계속 트리거되는 원인 파악.

- `dockStatus()` 가 `ensureCommandReady(reason: "dockStatus")` 호출 →
  `shouldWakeBeforeProbe(device)` 가 true 면 `wakeKnownCamera` 가 wake 송출
- heartbeat task 의 호출 경로도 동일 가능성

조치 후보:
- 직전 wake 가 N초 이내에 송출됐다면 추가 wake skip (wake debounce)
- `shouldWakeBeforeProbe` 의 기준 강화: `device.powerOn == true` 면 wake 생략

### 3.4 Phase 1.5 — `refreshConnection` cheap/heavy path 분리
**파일**: `Insta360BLEController.swift` — `refreshConnection`, `ensureCommandReady`

(우선순위 낮춤) 현재 분석상 capture probe timeout 의 원인은 채널 자체 dead 이지
probe 무게가 아님. 단, Phase 1.4 적용 후에는 채널이 살아있는 경우가 늘어날 것이므로
그때 다시 의미 있음.

- `lastPairCompletedUptimeNs` 트래킹 추가, pair 종료 시 timestamp 기록
- pair 후 30s 이내에는 capture probe 대신 `getOptions(BatteryStatus)` 단발만

### 3.5 Phase 1.2 — Bridge-level pair 직렬화
**파일**: `og-skill/mobile/ios/OGSkill/SyncField/SyncFieldBridgeModule.swift`

현재 `Insta360Scanner` 가 actor 라 `pair()` 는 직렬화돼있지만, `assignWristRole`
자체는 RN bridge task 두 개로 거의 동시에 시작됨. 사용자 보고상 UX 는 sequential 인데
JS layer 가 그렇게 호출 안 함.

추가 안전망:
- `SyncFieldBridgeModule` 에 `AsyncSerialQueue` 추가
- `assignWristRoleInternal` 전체를 enqueue
- 우선순위는 3.2 / 3.3 보다 낮음 — 기존 actor 직렬화로도 일단 동작은 함.

---

## 4. 핵심 진단 신호 (다음 회 분석용)

`Console.app` / Xcode console 에서 필터링할 prefix:

```
[Insta360Scanner.pair]
[Insta360Scanner.timing]
[Insta360BLE.pair]
[Insta360BLE.reconnect]
[Insta360BLE.wake]
[Insta360BLE.timing]
[Insta360BLE.gate]
[Insta360BLE]
[assignWristRole]
[SyncField]
API MISUSE
XPC connection invalid
```

특히 fast-path 분기 결과 (`fastPathCheck: cache=... scan=...`) 와
`metadata unavailable; accepting provisionally` 의 빈도가 다음 phase 결정의 근거.
