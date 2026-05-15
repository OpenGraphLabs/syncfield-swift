# Insta360 Collector Keep-Alive

> Multi-camera ingestion 도중 처리 대기 중인 카메라가 idle timeout으로 꺼지는 문제와, `Insta360Collector`에 prefetch pairing을 도입해 해결하는 설계.
>
> **Status**: Proposed · **Scope**: `SyncFieldInsta360.Insta360Collector` · **Breaking change**: No

---

## 1. 배경 — 문제 시나리오

ego + wrist 멀티 디바이스 셋업에서 자주 재현되는 실패:

| 단계 | 동작 | 카메라 상태 |
|---|---|---|
| 1 | 11분 녹화 (ego = iPhone, wrist L/R = Insta360 Go 3S 2대) | 양쪽 wrist 모두 BLE pair + 2초 heartbeat → 활성 유지 |
| 2 | `stopRecording()` → `disconnect()` | `Insta360Scanner.shared.unpairAll()` 호출 → 모든 BLE pair 해제 + heartbeat 정지 |
| 3 | `collectAllPendingEpisodes()` → `Insta360Collector.collectAll()` | iOS는 한 번에 하나의 WiFi AP만 가능 → **카메라 순차** 처리 |
| 4 | 1번째 wrist 다운로드 진행 (5~10분) | 다운로드 중 카메라는 socket heartbeat으로 활성. **2번째 wrist는 BLE pair 없음 → heartbeat 없음** |
| 5 | 2번째 wrist 차례 진입 시 `pair()` 호출 | **이미 idle timeout으로 전원 꺼져 있음** → wake 실패 또는 BLE timeout |

**근본 원인**: 카메라별 BLE keep-alive 메커니즘은 이미 라이브러리에 견고하게 구현되어 있으나(`Insta360BLEController.startHeartbeat`, 2초 주기 `sendHeartbeats`), `Insta360Collector`가 **현재 처리 중인 카메라만** pair하고 나머지는 자기 차례까지 방치함.

---

## 2. 기존 인프라 (변경 없음 — 그대로 활용)

라이브러리는 이미 멀티 BLE 페어링을 지원한다.

| 요소 | 위치 | 설명 |
|---|---|---|
| 공유 BLE 매니저 | `Insta360BLEController.swift:337` (`static let sharedManager: INSBluetoothManager`) | 프로세스 전역 1개 — 여러 디바이스 동시 연결 가능 |
| UUID별 디바이스 맵 | `Insta360Scanner.swift:35` (`pairedDevices: [String: INSBluetoothDevice]`) | multi-pair 자료구조가 이미 존재 |
| UUID별 controller 맵 | `Insta360Scanner.swift:36` (`pairedControllers: [String: Insta360BLEController]`) | 각 controller가 자기 heartbeat task 보유 |
| `pair()` idempotency | `Insta360Scanner.swift:176` | `if pairedDevices[bindingKey] != nil { return }` — 이미 페어링이면 no-op |
| Per-controller heartbeat | `Insta360BLEController.swift:2062` (`startHeartbeat()`), `:359` (`heartbeatTask`) | 2초 주기 `sendHeartbeats(with: nil)`. pair 직후(`:803`) 자동 시작 |
| 자동 reconnect | `Insta360BLEController.swift:1516`, `:1838` (`reconnectIfNeeded()`) | BLE 명령 시도 시 drop 감지하면 자동 재연결 |

**핵심**: Collector가 모든 대상 카메라를 사전 페어링하기만 하면, 각 controller의 heartbeat task가 카메라를 활성 유지해 준다. 추가 메커니즘이 필요 없다.

---

## 3. 권장 설계 — Prefetch Pairing

### 3.1 동작 비교

**Before** — `Insta360Collector.runCollect` (현행, Insta360Collector.swift:156~253):

```
runCollect:
  groups = groupByCamera(items)
  for (uuid, group) in groups:        ← 순차 진입
      pair(uuid)                       ← 이 시점에 처음 페어링
      controller.enableWiFiForDownload()
      controller.wifiCredentials()
      downloader.downloadBatch(...)    ← 5~10분
      (다른 카메라들은 이 동안 아무 처리 없음)
  finalizeWiFiRestore()
  removeCameraHotspotConfigurations()
```

**After** — prefetch pairing 도입:

```
runCollect:
  groups = groupByCamera(items)

  # Phase 1 (NEW) — 모든 대상 카메라 사전 페어링
  for (uuid, group) in groups:
      try: pair(uuid)                  ← controller.startHeartbeat() 자동
      prefetchedUUIDs.append(uuid)
      (실패는 fail-soft, 로그만)

  defer:                                ← cleanup 보장
      for uuid in prefetchedUUIDs:
          unpair(uuid)

  # Phase 2 — 기존 순차 다운로드 (변경 없음)
  for (uuid, group) in groups:
      pair(uuid)                       ← idempotent: prefetch 성공 시 no-op
      controller.enableWiFiForDownload()
      ...
      (다운로드 진행 중에도 다른 카메라들은 BLE heartbeat 2초 주기로 살아 있음)
```

### 3.2 변경 파일 / 분량

| 파일 | 변경 종류 | 분량 |
|---|---|---|
| `Sources/SyncFieldInsta360/Insta360Collector.swift` | 수정 (`runCollect` 함수 내부에 prefetch + defer cleanup 추가) | +~40 lines |
| `CHANGELOG.md` | 새 항목 추가 (예: 0.9.3 — Multi-camera collect keep-alive) | +5 lines |
| `docs/insta360-collector-keep-alive.md` | **본 문서** | 신규 |

og-skill (`SyncFieldBridgeModule.collectAllPendingEpisodes`)는 **변경 없음** — Pod 업데이트만으로 해결.

### 3.3 구현 디테일 (`Insta360Collector.runCollect`)

```swift
private func runCollect(
    items: [Insta360PendingSidecar.WithDir],
    progress: @escaping @Sendable (Progress) -> Void
) async throws -> [Result] {
    try Task.checkCancellation()
    let groups = Self.groupByCamera(items)

    // === Phase 1 — prefetch pairing ===
    //
    // 카메라들은 WiFi AP 제약으로 순차 처리되지만, 처리 대기 중인 카메라가
    // idle timeout으로 꺼지지 않도록 미리 BLE pair → controller 자체의
    // 2초 heartbeat가 처리 완료 시점까지 디바이스를 활성 유지.
    //
    // INSBluetoothManager.sharedManager가 프로세스 전역 공유이므로 동시
    // 페어링이 기본 지원됨. iOS BLE 동시 연결 한계(보통 8개 이상)에 비해
    // ego+wrist L/R 최대 3대는 충분히 여유.
    //
    // 일부 prefetch 실패는 fail-soft — 기존 Phase 2 루프가 카메라별로
    // pair를 다시 시도하므로 동작은 그대로 보존.
    var prefetchedUUIDs: [String] = []
    for (uuid, group) in groups {
        try Task.checkCancellation()
        do {
            try await Insta360Scanner.shared.pair(
                uuid: uuid,
                preferredName: group.first?.sidecar.bleName)
            prefetchedUUIDs.append(uuid)
            NSLog("[Insta360Collector] prefetch pair ok uuid=\(uuid)")
        } catch {
            NSLog("[Insta360Collector] prefetch pair failed uuid=\(uuid): \(error.localizedDescription) — will retry at per-camera step")
        }
    }

    // 처리 완료 시 prefetch한 카메라들 정리 (호스트가 collectAll 전에
    // unpairAll 상태였던 정상 흐름을 정확히 복원). throw/cancel 어느 경로든
    // cleanup이 실행되도록 defer + detached Task.
    defer {
        let toCleanup = prefetchedUUIDs
        Task { [toCleanup] in
            for uuid in toCleanup {
                try? await Insta360Scanner.shared.unpair(uuid: uuid)
            }
        }
    }

    // === Phase 2 — 기존 순차 다운로드 루프 (변경 없음) ===
    // (현행 line 162~243 그대로)
    var results: [Result] = []
    for (uuid, group) in groups {
        try Task.checkCancellation()
        do {
            try await Insta360Scanner.shared.pair(
                uuid: uuid,
                preferredName: group.first?.sidecar.bleName)
            // ... (이하 기존 코드 동일)
        } catch {
            // ... (기존 카메라 단위 실패 처리 동일)
        }
    }

    let finalDownloader = Insta360WiFiDownloader()
    await finalDownloader.finalizeWiFiRestore()
    await finalDownloader.removeCameraHotspotConfigurations()
    return results
}
```

---

## 4. 안전성 분석

| # | 항목 | 결론 |
|---|---|---|
| 1 | **API breaking change** | 없음 — `collectAll/collectEpisode/collectEpisodes` 시그니처 무변경 |
| 2 | **기존 흐름 보존** | prefetch가 실패해도 Phase 2 루프가 그대로 동작 → worst case는 현행과 동일 |
| 3 | **iOS BLE 동시 연결 한계** | iOS 한계 ~8개. ego+wrist 최대 3대로 충분히 여유 |
| 4 | **WiFi-BLE 라디오 간섭** | 한 카메라가 WiFi AP 진입 시 자체 BLE drop 가능하나, **다른 카메라들의 BLE는 별도 라디오라 영향 없음**. drop 발생 시 `reconnectIfNeeded()`가 자동 발동 |
| 5 | **`SessionOrchestrator`와의 상호작용** | `runCollect`는 `disconnect` 후에 호출되는 별도 흐름. 다른 진입점은 동일한 idempotent `pair()`를 사용하므로 충돌 없음 |
| 6 | **Cleanup 보장** | `defer` + detached Task로 정상/throw/cancellation 모든 경로에서 unpair 실행. `try?`로 cleanup 실패가 collect 결과를 가리지 않음 |
| 7 | **호스트 사용 가정** | 호스트는 `collectAll` 호출 전에 `disconnect`(= `unpairAll`)를 마쳐야 함. 이 가정이 깨지면 prefetch가 호스트의 페어링과 경합 가능 → 문서 §6에 명시 |

---

## 5. 검증 계획

### 5.1 단위 테스트

`Insta360Collector.groupByCamera`는 이미 pure helper(line 115~128)로 단위 테스트 가능. `Insta360Scanner.shared` actor 의존성으로 prefetch 자체의 통합 mocking은 제한적이지만 다음은 검증:

- `prefetchedUUIDs`가 `groupByCamera` 순서와 일치
- prefetch 부분 실패 시 `runCollect` 전체 throw 안 함

### 5.2 실기기 통합 테스트 (가장 중요)

| 시나리오 | 절차 | 합격 기준 |
|---|---|---|
| **A. Happy path (short)** | ego + wrist L/R, 5분 녹화 → stop → disconnect → collect | 양쪽 wrist mp4 모두 다운로드 성공. collect 종료까지 양쪽 LED 켜져 있음 |
| **B. Regression (long)** | 동일 셋업, 11~15분 녹화 후 collect (원래 문제 재현 길이) | 양쪽 wrist 다운로드 성공. 1번째 wrist 다운로드 종료 시점에 2번째 wrist가 여전히 활성 상태(육안 확인) |
| **C. Background mid-collect** | Collect 시작 → 30초 후 background → 30초 후 foreground | 다운로드 정상 진행 (NEHotspotConfiguration apply는 foreground 권장이므로 collect 단계 foreground 유지가 정상 사용) |
| **D. Cancellation** | Collect 시작 → 중간에 cancel | 모든 prefetched 카메라가 unpair됨 (`Insta360Scanner.shared.pairedUUIDs()` 검증) |
| **E. Single camera regression** | ego + wrist 1대로 5분 녹화 → collect | 기존과 동일하게 정상 동작 (prefetch가 single-camera에서도 무해) |

### 5.3 로그 추적

- `[Insta360Collector] prefetch pair ok uuid=<UUID>` — 카메라별 prefetch 성공
- 기존 `[Insta360BLE] sendHeartbeat` 또는 동급 로그 — 처리 대기 중인 카메라에서도 2초 주기 발신 확인
- BLE drop이 발생했을 경우 `Device disconnected` 후 `reconnectIfNeeded — re-paired` 자동 회복 흐름 확인

---

## 6. 사용자(호스트) 가이드

호스트 앱(예: og-skill의 `SyncFieldBridgeModule`)은 본 변경 후에도 **API 호출을 바꿀 필요가 없다**.

```swift
// 정상 흐름 (이미 og-skill이 이대로 동작)
try await session.stopRecording()
try await session.disconnect()                  // ← unpairAll 포함
try await Insta360Collector.shared.collectAll(  // ← 내부에서 prefetch + heartbeat 자동
    root: recordingsRoot,
    progress: { ... }
)
```

**가정**: 호스트가 `collectAll`을 호출하기 전에 모든 Insta360 페어링을 해제(`disconnect` → `unpairAll`)한 상태여야 한다. 그렇지 않은 경우 prefetch가 새 페어링을 추가하지 않을 수도 있고(idempotent), `defer` cleanup이 호스트가 외부에서 유지하려던 페어링까지 unpair할 위험이 있다.

→ 만약 호스트가 collect 도중 다른 BLE 명령(예: identify)을 병행해야 하면 issue로 제기. 추후 `KeepAliveOptions` 명시적 opt-in API 도입 검토.

---

## 7. Out of Scope (별도 후속 이슈)

| 항목 | 사유 |
|---|---|
| **BLE drop 시 즉시 reconnect watchdog** | 현재 `device(didDisconnect)`(Insta360BLEController.swift:2148)는 stop만 하고 다음 BLE 명령 시점에서야 reconnect. prefetch heartbeat이 정상 동작하면 drop 빈도가 낮으므로 이번 PR에서 제외. 후속 별도 추적 |
| **`KeepAliveOptions` 명시 API** | 초기 버전은 default-on 단순화. 외부 페어링 관리 요구가 생기면 `collectAll(root:keepAlive:progress:)` 형태로 opt-out 추가 검토 |
| **호스트 UX 진척 표시** | prefetch 페이즈가 1~5초 소요될 수 있어 사용자가 진행률 0%에서 잠깐 멈춘 듯 보일 수 있음. "Pairing cameras…" 같은 사전 단계 라벨은 호스트(og-skill) 측 UX 개선으로 분리 |

---

## 8. 참고 코드 위치

| 주제 | 파일 · 라인 |
|---|---|
| Collector 진입점 | `Sources/SyncFieldInsta360/Insta360Collector.swift:156` (`runCollect`) |
| Collector 순차 루프 주석 | `Sources/SyncFieldInsta360/Insta360Collector.swift:165` (`iOS can only be on one WiFi AP at a time`) |
| 멀티 BLE pair 자료구조 | `Sources/SyncFieldInsta360/Insta360Scanner.swift:35-36` |
| `pair()` idempotency | `Sources/SyncFieldInsta360/Insta360Scanner.swift:176` |
| 공유 BLE 매니저 | `Sources/SyncFieldInsta360/Insta360BLEController.swift:337` |
| Heartbeat task | `Sources/SyncFieldInsta360/Insta360BLEController.swift:2062` (`startHeartbeat`), `:2074` (`sendHeartbeat`) |
| Heartbeat 자동 시작 시점 | `Sources/SyncFieldInsta360/Insta360BLEController.swift:803` (pair 직후), `:880` (reconnect 직후) |
| 자동 reconnect | `Sources/SyncFieldInsta360/Insta360BLEController.swift:1516`, `:1838` |
| 호스트 collect 진입점 (og-skill) | `mobile/ios/OGSkill/SyncField/SyncFieldBridgeModule.swift:1374` (`collectAllPendingEpisodes`) |
| 호스트 disconnect 시 unpairAll (og-skill) | `mobile/ios/OGSkill/SyncField/SyncFieldBridgeModule.swift:2553` |
