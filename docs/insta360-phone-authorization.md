# Insta360 Phone Authorization

> syncfield-swift이 Insta360 GO 3S의 **Phone Authorization** 흐름을 자력으로 수행하도록 통합하는 설계 문서. 공식 Insta360 앱 의존을 제거하고, 호스트 앱(og-skill)이 새 사용자에게 1회 카메라 승인 UX를 자연스럽게 안내하도록 한다.

## 한 줄 요약

Insta360 GO 3S는 카메라 내부에 **phone-level authorized device list**를 보유한다. 인증되지 않은 폰에서 BLE commands를 보내면 silent rejection 또는 timeout으로 실패한다. Insta360 SDK V1.9.2(2025-11) 헤더는 `checkPhoneAuthorizationWithOptions:initiatorType:deviceId:completion:` API를 GO 3S 전용(`availability(go3)`)으로 공개하지만, syncfield-swift도 og-skill도 한 번도 호출하지 않는다. 이 문서는 그 API를 SDK lifecycle에 **Throwable + Explicit Recovery** 패턴으로 통합하고, og-skill의 페어링 UX에 자연스럽게 끼우는 production-ready 설계다.

---

## 왜 필요한가

### 베타 사용자 사례 (2026-05)

본인 폰에서 정상 동작하던 카메라가, 같은 카메라를 받은 베타 사용자 20명 중 다수에서 "녹화 시작 실패 — Insta360 카메라에 연결하지 못했어요" alert만 뜨고 멈추는 현상 발생. 실험적으로 친구 폰에 Insta360 공식 앱을 깔고 카메라 1회 승인한 뒤 OG Skill을 실행하니 정상 동작. **카메라 측 phone authorization 미등록이 결정적 원인.**

### SDK 헤더가 직접 보여주는 인증 모델

`INSPhoneAuthorizationStatus.h:12-19`:

```objc
typedef NS_ENUM(NSUInteger, INSPhoneAuthorizationState) {
    INSPhoneAuthorizationStateAuthorized,
    INSPhoneAuthorizationStateUnauthorized,
    INSPhoneAuthorizationStateSystemBusy,
    INSPhoneAuthorizationStateConnectedByOtherPhone,
    INSPhoneAuthorizationStateConnectedByOtherWatch,
    INSPhoneAuthorizationStateConnectedByOtherCyclocomputer,
};

@property (nonatomic) NSString *deviceId;
```

확정 사실:
1. 카메라는 **phone-level authorization 상태**를 보유.
2. 동시 active connection은 1대만 허용 (`ConnectedByOtherPhone`).
3. `deviceId` 기반 식별 — multi-device authorized list 모델.

### 두 가지 auth의 구분

GO 3S에는 **서로 다른 두 인증 메커니즘**이 카메라 내부에 존재한다:

| 종류 | SDK API | 동작 | 현재 syncfield-swift |
|---|---|---|---|
| Wakeup Auth | `INSBluetoothConnection.writeWakeupAuthDataToCamera`<br>(`Headers/INSBluetoothConnection.h:47`) | BLE characteristic write로 wake용 auth data 기록. 사용자 UI 없음. | **호출 중** (`Insta360BLEController.swift:835-852`) |
| Phone Authorization | `checkPhoneAuthorizationWithOptions:initiatorType:deviceId:completion:`<br>(`Headers/INSCameraBasicCommands.h:271-286`, `availability(go3)`) | deviceId 전송 → 카메라 LCD에 사용자 승인 UI → 영구 등록. | **호출하지 않음** |

두 인증 모두 통과해야 commands가 실행된다. 현재 코드는 wakeup auth만 시도하고 phone authorization은 건너뛰므로, 카메라는 commands를 거절하고 commands들은 timeout으로 silent fail한다.

`Insta360BLEController.swift:838-842`의 SDK 작성자 주석이 이미 이 갭을 시인하고 있다:

> "Do not opportunistically send command-channel provisioning here. GO 3S often accepts the BLE link before its command channel is ready; background `setOptions` / authorization probes then race recording preflight and can poison the SDK connection with 444 disconnects. **Wake provisioning needs an explicit foreground flow.**"

이 문서가 그 "explicit foreground flow"를 정의한다.

---

## SDK가 제공하는 원시 API

### `checkPhoneAuthorizationWithOptions:initiatorType:deviceId:completion:`

두 프로토콜에서 동일 시그니처로 노출됨 — BLE 채널만으로 호출 가능.

**`Headers/INSCameraBasicCommands.h:271-286`**:

```objc
/*!
 * check authorization for the phone
 * availability(go3)
 */
- (void)checkPhoneAuthorizationWithOptions:(INSCameraRequestOptions *_Nullable)options
                             initiatorType:(INSCheckAuthorizationInitiatorType)initiatorType
                                  deviceId:(NSString *)deviceId
                                completion:(void (^)(NSError * _Nullable,
                                            INSPhoneAuthorizationStatus * _Nullable))completion;

/*!
 * cancel check authorization. This will stop the UI on camera for authorization
 * availability(go3)
 */
- (void)cancelCheckPhoneAuthorizationWithOptions:(INSCameraRequestOptions *_Nullable)options
                                       completion:(void (^)(NSError * _Nullable))completion;
```

**`Headers/INSBluetoothCommands.h:25-30`**도 동일 시그니처를 BLE 채널 프로토콜에 노출.

핵심 동작:
- 호출 시 **카메라 LCD에 승인 UI 표시** (취소 메서드 주석이 명시).
- 사용자 응답까지 비동기 대기.
- `INSPhoneAuthorizationStatus`의 `state`로 결과 반환.

### `INSCheckAuthorizationInitiatorType` (`Headers/INSConnectionUtils.h:12-35`)

```objc
typedef NS_ENUM(NSUInteger, INSCheckAuthorizationInitiatorType) {
    INSCheckAuthorizationInitiatorTypeUnknown = 0,
    INSCheckAuthorizationInitiatorTypePhoneIos = 1,     // ← 우리가 사용
    INSCheckAuthorizationInitiatorTypePhoneAndroid = 2,
    INSCheckAuthorizationInitiatorTypePhoneHarmonyos = 3,
    INSCheckAuthorizationInitiatorTypeWatchWatchos = 16,
    // ...
};
```

### `INSConnectionUtils.authorizationId` (`Headers/INSConnectionUtils.h:38-39`)

```objc
/// 获取授权id
+ (NSString *)authorizationId;
```

SDK가 직접 제공하는 deviceId 생성 헬퍼. 동일 디바이스에서 일관된 값 반환 — 임의로 생성하지 말고 그대로 사용.

### `INSPhoneAuthorizationResult` (`Headers/NSNotification+INSCamera.h:357-363`)

```objc
typedef NS_ENUM(NSUInteger, INSPhoneAuthorizationResult) {
    INSPhoneAuthorizationResultUnknown,
    INSPhoneAuthorizationResultSuccess,
    INSPhoneAuthorizationResultReject,
    INSPhoneAuthorizationResultTimeout,
    INSPhoneAuthorizationResultSystemBusy,
};
```

실기기 검증 결과, GO 3S에서는 `checkPhoneAuthorization`의 `completion`이 최종 사용자 응답이 아니라 **초기 authorization state**를 먼저 반환할 수 있다. 특히 `.Unauthorized`는 "거절"이 아니라 "카메라 LCD에 승인 요청을 표시했고 사용자 결정을 기다려야 함"으로 처리해야 한다. 최종 성공/거절/타임아웃은 `INSCameraAuthorizationResultNotification`의 `userInfo["result"]` (`INSPhoneAuthorizationResult`)를 기다려 확정한다.

---

## 설계 철학: Throwable + Explicit Recovery

iOS 시스템 권한(`CLLocationManager`, `AVCaptureDevice.requestAccess`) 패턴과 동형:

1. `Insta360CameraStream.connect(context:)`가 BLE 페어링 후 phone authorization 상태를 **자동 점검**한다.
2. 캐시 hit → 곧장 통과. 캐시 miss → **`Insta360Error.phoneAuthorizationRequired(uuid:deviceId:)` throw**.
3. 호스트 앱이 이 에러를 catch → UX 표시 → `Insta360CameraStream.requestPhoneAuthorization()` **명시 호출** → 성공 시 `connect(context:)` 재호출.
4. 한 번 승인된 페어는 `Insta360IdentityStore`에 영구 캐시 → 다음부터 자동 통과.

SDK는 **상태 머신 + 캐시 + 카메라 측 통신**을 책임지고, 호스트 앱은 **UX(modal, countdown, copy, retry)** 를 완전히 제어한다. 깊이 결합된 UI 가정을 SDK에 박지 않는다.

---

## syncfield-swift Public API (신규)

### `Insta360CameraStream` 확장

기존 lifecycle 메서드(`Insta360CameraStream.swift:103-482`)에 `connect(context:)`의 동작만 바꾸고, 신규 메서드 3개를 추가한다.

```swift
extension Insta360CameraStream {

    /// 카메라가 우리 deviceId로 phone authorization 등록되어 있는지 캐시 기반 조회.
    /// Disk I/O만 발생. BLE 통신 없음. 호스트 UI 분기에 사용.
    public var phoneAuthorizationStatus: PhoneAuthorizationCacheState { get }

    /// 카메라 LCD에 승인 UI를 띄우고 사용자 응답을 대기. 성공 시 IdentityStore에 캐시.
    /// 호출 전에 BLE 연결 + command channel ready 상태여야 함 — 내부에서 `ensureCommandReady` 자동 호출.
    ///
    /// - Parameter timeoutSeconds: 카메라 측 UI 타임아웃. 기본 30s.
    /// - Throws:
    ///   - `phoneAuthorizationRejected` — 사용자가 카메라 LCD에서 거절.
    ///   - `phoneAuthorizationTimedOut` — 사용자 무응답 timeout.
    ///   - `phoneAuthorizationCanceled` — 호스트가 `cancelPhoneAuthorization` 호출.
    ///   - `notPaired` / `commandFailed` — BLE/SDK 레벨 실패.
    public func requestPhoneAuthorization(
        timeoutSeconds: TimeInterval = 30
    ) async throws

    /// 진행 중인 카메라 측 승인 UI를 즉시 해제.
    /// 사용자가 호스트 modal을 dismiss했을 때 **반드시** 호출. 호출하지 않으면 카메라 LCD에 UI가 잔류.
    public func cancelPhoneAuthorization() async
}

public enum PhoneAuthorizationCacheState: Sendable, Equatable {
    case unknown                  // 캐시 미존재 (첫 페어링 시나리오)
    case authorized(at: Date)     // 인증 완료 + 시각
    case failed                   // 가장 최근 시도 실패 — 재시도 권장
}
```

### `connect(context:)` 동작 변경

기존 흐름 (`Insta360CameraStream.swift:123`):

1. BLE 페어링 / 바인딩
2. command channel ready 대기
3. wake auth data write
4. return

신규 흐름 (마지막에 인증 점검 추가):

5. **NEW** — `IdentityStore.isPhoneAuthorized(serialLast6:)` 조회.
6. **NEW** — 캐시 hit → return.
7. **NEW** — 캐시 miss → `throw .phoneAuthorizationRequired(uuid:deviceId:)`.

> **Note.** `checkPhoneAuthorization`은 카메라 LCD 승인 UI를 띄우는 interactive 호출이다. 숨은 5초 probe로 사용하면 호스트 앱의 30초 UX와 카메라 UI가 어긋나므로, 반드시 호스트 modal이 열린 뒤 `requestPhoneAuthorization()`의 명시 호출에서만 실행한다.

### `Insta360Error` 신규 케이스

`Insta360Error.swift`(현재 36-66 라인의 enum)에 추가:

```swift
public enum Insta360Error: Error, Sendable {
    // ... 기존 cases ...

    /// 카메라가 우리 deviceId를 authorized list에 등록하지 않음.
    /// 호스트 앱은 `requestPhoneAuthorization()`을 호출해 UX 흐름을 시작해야 함.
    case phoneAuthorizationRequired(uuid: String, deviceId: String)

    /// 카메라 측 LCD UI에서 사용자가 거절을 선택.
    case phoneAuthorizationRejected

    /// 카메라 측 UI가 사용자 응답 없이 timeout.
    case phoneAuthorizationTimedOut

    /// 호스트 앱이 `cancelPhoneAuthorization()`을 호출.
    case phoneAuthorizationCanceled
}
```

`localizedDescription`도 분기 추가 (디버그 로그용).

### `Insta360IdentityStore` 확장

기존 캐시 파일 `~/Library/Application Support/SyncFieldInsta360/identities.json` (`Insta360IdentityStore.swift:44`)의 record 구조체에 옵셔널 필드 추가. **JSON optional이라 backwards compatible** — 기존 파일은 nil로 디코드되어 첫 connect 시 자연스럽게 마이그레이션된다.

```swift
public struct Record: Codable, Sendable {
    public let serialLast6: String
    public let lastKnownUUID: String?
    public let lastKnownBLEName: String?
    public let firstPairedAt: Date
    public let lastSeenAt: Date

    /// NEW — phone authorization 성공 시각. nil이면 미인증.
    public let phoneAuthorizedAt: Date?
}
```

신규 actor 메서드:

```swift
public actor Insta360IdentityStore {
    // ... 기존 ...

    public func markPhoneAuthorized(serialLast6: String, at: Date = .now) async
    public func clearPhoneAuthorization(serialLast6: String) async
    public func isPhoneAuthorized(serialLast6: String) async -> Bool
}
```

**캐시 무효화 조건:**

- `phoneAuthorizationRejected` / `phoneAuthorizationTimedOut` throw 직전에 `clearPhoneAuthorization` 자동 호출.
- 카메라 펌웨어 업데이트나 공장 초기화로 auth list가 초기화될 수 있다. 운영 중 stale cache가 확인되면 command failure를 phone authorization required로 승격하는 별도 복구 경로를 추가한다.

### `Insta360BLEController` 내부 헬퍼 (구현 메모, public 아님)

```swift
extension Insta360BLEController {
    /// SDK의 checkPhoneAuthorization을 호출. `ensureCommandReady` 통과를 보장한 뒤 사용.
    func performPhoneAuthorization(
        deviceId: String,
        timeoutSeconds: TimeInterval
    ) async throws -> INSPhoneAuthorizationState

    /// 진행 중 UI 해제. cancelCheckPhoneAuthorization SDK 콜.
    func cancelPendingPhoneAuthorization() async
}
```

내부 호출 시점: 호스트가 `requestPhoneAuthorization`을 명시 호출한 뒤 `ensureCommandReady`가 끝난 시점. `checkPhoneAuthorization` completion의 `.Unauthorized`는 final reject가 아니라 `INSCameraAuthorizationResultNotification` 대기로 이어진다.

---

## Lifecycle 통합

### 첫 연결 (인증 없음) 시퀀스

```
Host App                  syncfield-swift             Camera
   │                          │                          │
   ├── Scanner.shared.scan() ─┤                          │
   │                          ├── BLE scan ─────────────►│
   │◄── DiscoveredInsta360 ───┤                          │
   │                          │                          │
   ├── stream.connect(ctx) ───┤                          │
   │                          ├── BLE pair ─────────────►│
   │                          ├── waitForCommandManagerReady
   │                          ├── writeWakeupAuthData ──►│
   │                          ├── isPhoneAuthorized(cache)
   │                          │     → false
   │◄── throws phoneAuthorizationRequired(uuid, deviceId)
   │
   │── (호스트 앱 UX: PhoneAuthorizationModal "카메라에서 승인해주세요")
   │
   ├── stream.requestPhoneAuthorization() ──┐
   │                          ├── ensureCommandReady
   │                          ├── checkPhoneAuthorization
   │                          ├──────────────────────────►│ (LCD: 승인?)
   │                          │                          │ ← user taps OK
   │                          │◄─── notification .Success │
   │                          ├── IdentityStore.markPhoneAuthorized
   │◄── return ────────────────┤
   │
   ├── stream.connect(ctx) (retry) ─┤
   │                                 ├── 캐시 hit → 즉시 return
   │◄── return ──────────────────────┤
   │
   ├── orchestrator.startRecording() ─┐ ... (정상 흐름)
```

### 재연결 (캐시 hit) 시퀀스

```
Host App                  syncfield-swift             Camera
   ├── stream.connect(ctx) ───┤
   │                          ├── BLE pair ─────────────►│
   │                          ├── waitForCommandManagerReady
   │                          ├── writeWakeupAuthData ──►│
   │                          ├── isPhoneAuthorized(cache) → true
   │◄── return ────────────────┤
   │   (carries to startRecording without modal)
```

---

## og-skill 통합 가이드

### Bridge 메서드 추가

기존 패턴(`SyncFieldBridgeModule.m:39-57`의 페어링 관련 메서드들)과 동형으로 두 메서드 노출.

**`og-skill/mobile/ios/OGSkill/SyncField/SyncFieldBridgeModule.m`** (extern 선언):

```objc
RCT_EXTERN_METHOD(requestPhoneAuthorization:(NSString *)uuid
                                  timeoutMs:(nonnull NSNumber *)timeoutMs
                                    resolve:(RCTPromiseResolveBlock)resolve
                                     reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(cancelPhoneAuthorization:(NSString *)uuid
                                   resolve:(RCTPromiseResolveBlock)resolve
                                    reject:(RCTPromiseRejectBlock)reject)
```

**`SyncFieldBridgeModule.swift`** — 해당 메서드 구현:

- `requestPhoneAuthorization(uuid:timeoutMs:resolve:reject:)` → 해당 UUID의 `Insta360CameraStream` 인스턴스 lookup → `requestPhoneAuthorization(timeoutSeconds:)` 호출 → 결과/에러를 RN promise로 surface.
- `cancelPhoneAuthorization(uuid:resolve:reject:)` → 동일 인스턴스 lookup → `cancelPhoneAuthorization()` 호출.

**RN promise reject 에러 코드 매핑:**

| Swift error | RN code | i18n key |
|---|---|---|
| `.phoneAuthorizationRequired` | `PHONE_AUTH_REQUIRED` | `device.phone_auth.required` (안내) |
| `.phoneAuthorizationRejected` | `PHONE_AUTH_REJECTED` | `device.phone_auth.rejected_msg` |
| `.phoneAuthorizationTimedOut` | `PHONE_AUTH_TIMEOUT` | `device.phone_auth.timeout_msg` |
| `.phoneAuthorizationCanceled` | `PHONE_AUTH_CANCELED` | (조용히, 토스트 없음) |
| 기타 (BLE 끊김 등) | 기존 `SYNCFIELD_ERROR` | 기존 메시지 매핑 |

**진행률 이벤트** — modal countdown 갱신용:

```
event: 'syncfield:phoneAuthProgress'
payload: { uuid: string, secondsRemaining: number,
           state: 'waiting' | 'success' | 'failed' }
```

호스트 modal이 이 이벤트를 ≤1s 간격으로 emit 받아 progress bar 업데이트.

### `useDeviceDiscoveryMachine.ts` 상태머신 확장

기존 phase enum(`og-skill/mobile/src/features/device/useDeviceDiscoveryMachine.ts:5-12`)에 신규 phase 추가:

```typescript
type DeviceDiscoveryPhase =
  | 'idle' | 'scanning' | 'identifying' | 'assigning'
  | 'awaiting_phone_auth'  // NEW
  | 'done' | 'error';

interface AuthState {
  phase: 'awaiting_phone_auth';
  uuid: string;
  role: 'left' | 'right';
  secondsRemaining: number;
}
```

**전이:**

- `assigning` → (`assignWristRole` 결과 `PHONE_AUTH_REQUIRED`) → `awaiting_phone_auth`
- `awaiting_phone_auth` → (modal `requestPhoneAuthorization` 성공) → 카메라 재바인딩 → `assigning` 또는 `done`
- `awaiting_phone_auth` → 사용자 취소 / timeout / reject → 사용자 결정에 따라 `error` (재시도 UI 표시) 또는 `idle`

### `PhoneAuthorizationModal` 컴포넌트

신규 컴포넌트 위치: `og-skill/mobile/src/features/device/PhoneAuthorizationModal.tsx`.

**Props:**

```typescript
{
  visible: boolean;
  uuid: string;
  role: 'left' | 'right';
  secondsRemaining: number;
  errorState?: 'timeout' | 'rejected' | 'system_busy';
  onCancel: () => void;
  onRetry: () => void;
}
```

**UI 구성 (위에서 아래):**

1. **헤더** — `device.phone_auth.title_left` / `title_right` (역할 표시)
2. **메인 안내문** — `device.phone_auth.body` (Action Pod에서 [확인] 누르라는 짧은 한 줄)
3. **보조 텍스트** — `device.phone_auth.first_time_hint` (처음 사용자 안심 제공)
4. **Countdown progress bar** — 0 ~ 30s, 부드러운 감소
5. **하단 버튼** — "취소" → `onCancel` (modal close + `cancelPhoneAuthorization` 필수 호출)
6. **에러 상태 inline display** — `errorState` 있으면 메시지 + "다시 시도" 버튼

> **일러스트 없이 텍스트로 충분.** 공식 Insta360 앱은 Action Pod 일러스트를 사용하지만, 우리 사용 시나리오는 **Action Pod 도킹 사용에 한정**(베타 배포 구성)이라 짧은 텍스트 안내 한 줄로 충분히 직관적. 자산 추가 작업 생략.

### `RecordingScreen` 폴백 처리

이미 setup을 완료한 사용자가 첫 녹화에서 인증 누락이 드러나는 케이스도 흡수해야 한다.

`og-skill/mobile/src/features/recording/recordingStartErrors.ts:8-12`의 기존 분류 regex 앞에 phone auth 분기를 추가:

```typescript
export function recordingStartFailureMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error ?? '');
  if (raw.startsWith('recording.')) return raw;

  // NEW — phone auth는 alert가 아니라 modal로 처리.
  if (raw.startsWith('PHONE_AUTH_')) {
    return 'recording.phone_auth_required_hint';
  }

  if (/timed out|timeout/i.test(raw)) return 'recording.camera_connect_timeout_msg';
  // ... 기존 분류 ...
}
```

`RecordingScreen.tsx:451-454`의 alert 분기 직전에 raw가 `PHONE_AUTH_REQUIRED`로 시작하면 alert 대신 `PhoneAuthorizationModal`을 표시 → 성공 시 자동으로 `beginRecording` 재시도.

### i18n 카피 (`og-skill/mobile/src/i18n/ko.json`)

```json
{
  "device": {
    "phone_auth": {
      "title_left": "왼손목 카메라 승인",
      "title_right": "오른손목 카메라 승인",
      "body": "Action Pod 화면에서 [확인]을 눌러 연결을 허용해주세요.",
      "first_time_hint": "처음 연결하는 카메라는 1회 승인이 필요해요. 이후엔 자동으로 연결돼요.",
      "countdown": "{{seconds}}초 안에 응답해주세요",
      "cancel": "취소",
      "retry": "다시 시도",
      "timeout_msg": "응답 시간이 초과됐어요. Action Pod 화면이 켜져 있는지 확인한 뒤 다시 시도해주세요.",
      "rejected_msg": "카메라에서 승인이 거절됐어요. 다시 시도하면 Action Pod에 승인 요청이 다시 표시돼요.",
      "system_busy_msg": "카메라가 다른 작업 중이에요. 잠시 후 다시 시도해주세요.",
      "connected_by_other_msg": "이 카메라는 지금 다른 폰에 연결되어 있어요. 다른 폰에서 OG Skill 또는 Insta360 앱을 닫은 뒤 다시 시도해주세요."
    }
  },
  "recording": {
    "phone_auth_required_hint": "카메라 승인이 필요해요. 잠시 후 안내가 표시돼요."
  }
}
```

**카피 결정 메모:**
- "확인" 단어는 공식 Insta360 앱이 사용하는 카피와 동일 — 사용자가 카메라 LCD에서 보는 실제 버튼 라벨이므로 정확히 매칭.
- 단독(Action Pod 미사용) GO 3S 셔터 버튼 케이스는 안내하지 않음 — 베타 배포 구성이 Pod 도킹 사용이라 단순화. 향후 단독 사용 시나리오가 생기면 별도 분기 추가.

영문판 `en.json`에 대응 키 추가.

### 빌드 / pod 영향

- `Frameworks/Insta360/INSCameraServiceSDK.xcframework` 헤더는 변경 없음 — V1.9.2에 이미 모든 API 존재.
- syncfield-swift 신규 버전 릴리즈 후 `og-skill/mobile/ios/Podfile`의 syncfield-swift 의존성 버전 업데이트 + `pod install` 필요.

---

## 에지 케이스

### 멀티 카메라 (양손목)

`assignWristRole` 호출이 카메라마다 별도 → `PHONE_AUTH_REQUIRED` throw도 카메라마다 별도. modal은 **순차적으로** 표시:

1. 왼손목 카메라 binding → throw → 왼손목용 modal → 사용자가 왼손목 카메라 LCD에서 승인 → 캐시 → 재시도 OK.
2. 오른손목 카메라 binding → throw → 오른손목용 modal → ... → 재시도 OK.

병렬 modal은 하지 않는다 (사용자 인지 부하 + BLE 채널 경합 + 카메라 LCD가 작아 어느 쪽을 누르는지 혼란).

### Modal dismiss 처리

사용자가 modal을 닫을 때 반드시:

```typescript
await SyncFieldBridge.cancelPhoneAuthorization(uuid);
```

호출. 호출하지 않으면 카메라 LCD에 승인 UI가 잔류하여 다음 사용 시 사용자 혼란을 일으킨다.

`PhoneAuthorizationModal`의 `onCancel`에서 항상 호출 보장. AppState가 background로 전환될 때도 호출 (AppState listener).

### 캐시 만료

현재 가정: 카메라 측 authorized list는 장기 유지된다. 만료/초기화가 운영 중 발견되면:

- 카메라 공장 초기화 → cached authorized가 stale일 수 있음.
- 운영 중 stale cache가 확인되면 clock sync / Wi-Fi credential command failure를 `phoneAuthorizationRequired`로 승격하고 cache를 clear하는 복구 경로를 추가한다.

### 펌웨어 미지원 / API 미응답

`availability(go3)` 명시이지만 옛 펌웨어가 API에 응답하지 않을 가능성:

- `requestPhoneAuthorization`의 `checkPhoneAuthorization` 시작 또는 authorization notification 대기가 timeout → `.phoneAuthorizationTimedOut`.
- 사용자에게 "카메라 펌웨어 업데이트 권장" 별도 메시지를 띄울지는 firmware 버전 조회 후 결정 (현재 코드는 `INSBluetoothConnection.readFirmwareWithCompletion`을 사용 가능). 본 작업의 범위는 throw 흐름까지, firmware 가이드 분기는 운영 데이터 모으고 별도 작업.

### BLE 끊김 도중 인증 진행

`requestPhoneAuthorization` 내부에서 `ensureCommandReady` 1회 명시 호출 — 재연결 자동. 그래도 끊기면 기존 `Insta360Error.notPaired` 그대로 throw → 호스트는 modal 닫고 페어링 재시도 권장.

### `ConnectedByOtherPhone` 응답

다른 폰이 같은 카메라에 BLE 점유 중일 때 발생. 호스트 메시지:

> "이 카메라는 지금 다른 폰에 연결되어 있어요. 다른 폰에서 OG Skill 또는 Insta360 앱을 닫은 뒤 다시 시도해주세요."

별도 i18n 키 `device.phone_auth.connected_by_other_msg` 추가. 본 작업에 포함.

---

## 마이그레이션

### 기존 사용자 (이미 페어링 캐시 보유)

`IdentityStore`의 모든 기존 record는 `phoneAuthorizedAt == nil` → `isPhoneAuthorized → false`. 따라서:

- 신규 빌드 첫 실행 → 첫 connect에서 cache miss → modal 표시.
- 사용자가 (예전에 공식 앱에서) 이미 카메라에 인증한 상태 → modal 직후 `requestPhoneAuthorization`이 `.Authorized`를 받아 캐시 작성 후 자동 진행.
- 인증 안 된 사용자 → modal → Action Pod 승인 → notification success → 캐시.

**모든 기존 사용자가 첫 사용 시 자연스럽게 마이그레이션**된다 — 별도 onboarding 화면 불필요.

### 베타 배포 임시 우회 (이번 통합 배포 전)

이번 통합이 production 배포되기 전까지의 임시 가이드: "Insta360 공식 앱을 깐 뒤 카메라에 1회 연결 → 그 다음 OG Skill 사용." 이미 본 작업 직전 실험에서 검증 완료. `docs/insta360.md`의 **Gotchas** 섹션에 임시 안내를 추가하고, 통합 배포 후 제거.

### 점진 배포

og-skill 측에서 RN config flag(예: `EXPERIMENTAL_PHONE_AUTH`)로 게이팅. 초기에는 내부 사용자 → 안정화 후 전체 ON. SDK는 항상 새 동작이지만, og-skill 측이 throw를 catch하지 않으면 alert로 fall through (이미 silent fail이었던 케이스가 명시적 에러로 변하는 것이라 strictly better).

---

## 검증 (Verification)

### Unit 테스트

- `Insta360IdentityStoreTests` — `phoneAuthorizedAt` round-trip / `markPhoneAuthorized` / `clearPhoneAuthorization` / `isPhoneAuthorized` 동작 (`syncfield-swift/Tests/SyncFieldInsta360Tests/`).
- `Insta360PendingResolverTests` 동일 컨벤션 참고.

### Manual 시나리오

| ID | 시나리오 | 기대 동작 |
|---|---|---|
| A | 공장 초기화 카메라 + 새 디바이스 fresh install → setup → 양손목 binding | 카메라마다 modal → LCD 승인 → 캐시 → 녹화 OK |
| B | A 마친 동일 디바이스 앱 재실행 → 녹화 | modal 없이 즉시 시작 |
| C | A 도중 사용자가 modal "취소" | 카메라 LCD UI 즉시 사라짐 (`cancelCheckPhoneAuthorization`) |
| D | 본인 폰에서 사용 후 → 친구 폰 fresh install → 같은 카메라 | 친구 폰 modal → 친구가 LCD 승인 → 캐시 → 친구 폰 정상 |
| E | 양손목 모두 미인증 | 순차 modal 2회, 각각 별도 카메라 LCD |
| F | modal countdown 만료 (사용자 무응답) | `phoneAuthorizationTimedOut` → inline error + "다시 시도" |
| G | 카메라 LCD에서 사용자가 "거절" | `phoneAuthorizationRejected` → inline error + "다시 시도" |
| H | 본인 폰에서 앱 켜진 채로 친구 폰 시도 | `ConnectedByOtherPhone` 메시지, 본인 폰 종료 안내 |

### 카메라 측 UI 동작 (공식 앱 흐름으로 확인됨)

공식 Insta360 앱의 새 카메라 첫 연결 흐름에서 동일 API가 호출되는 것을 시각적으로 확인:

- Action Pod 도킹 상태에서 카메라 LCD에 `[확인]` 버튼이 표시됨.
- 사용자가 LCD `[확인]` 터치 → `INSPhoneAuthorizationResultSuccess` 반환.
- 무응답 → `INSPhoneAuthorizationResultTimeout` (시간 정확치는 검증 시 측정).

구현 첫 빌드의 검증 항목: 공장 초기화 카메라로 우리 SDK가 호출 시 동일 LCD 흐름이 재현되는지만 확인. 일러스트는 사용하지 않으므로 시각 자산 작업 불필요.

### 로컬 SDK 링크

og-skill의 syncfield-swift 의존성을 remote에서 **local path로 전환해둠**. 따라서 본 문서의 변경을 syncfield-swift에 반영하면 og-skill을 Xcode로 빌드만 해도 즉시 함께 들어간다. 별도 syncfield-swift 릴리즈/태그/`pod update` 없이 syncfield-swift ↔ og-skill 양쪽을 동시에 수정해가며 테스트 가능. production 배포 직전에 다시 remote 의존성으로 되돌리면 됨.

### 로컬 테스트용 카메라 리셋 방법

반복 테스트로 first-time 인증 흐름을 도려면 카메라 측 authorized list를 비워야 한다. SDK에는 GO 3S용 deauth API가 노출되어 있지 않으므로:

- **방법: 공장 초기화 (Option A).** Action Pod 설정 메뉴 → Reset → Factory Reset. paired 폰 + WiFi + 설정이 모두 초기화되므로 베타 사용자가 새 박스를 푼 상태와 동일해진다. 본 작업의 표준 reset 방법으로 채택.
- 폰 측 캐시(`identities.json`)는 앱 재설치 또는 Xcode container 삭제로 비움.

> 카메라 측 authorized list는 펌웨어가 영속 보관 → 공장 초기화로만 비울 수 있음. 폰 측 `[INSConnectionUtils authorizationId]`는 재설치에도 같은 값을 돌려주는 것으로 관찰되지만(앞선 사용자 확인), 백킹 메커니즘은 헤더로 단정 불가. 따라서 앱 재설치만으로는 first-time 흐름이 재현되지 않으며 카메라 측 리셋이 필수.

### PostHog 계측 (베타 모니터링)

이번 통합 배포와 동시에 추가:

- `phone_auth_required` — `{ uuid, role, source: 'setup' | 'recording' }`
- `phone_auth_succeeded` — `{ uuid, elapsed_sec }`
- `phone_auth_failed` — `{ uuid, reason: 'rejected' | 'timeout' | 'canceled' | 'connected_by_other' | 'other' }`

베타 배포 시 자력 인증 성공률과 시나리오별 실패율을 즉시 추적 가능.

---

## 작업 순서 (구현)

### syncfield-swift

1. `Insta360Error` 케이스 추가 (`Insta360Error.swift`).
2. `Insta360IdentityStore` 스키마 확장 + 메서드 (`Insta360IdentityStore.swift`).
3. `Insta360BLEController.performPhoneAuthorization` / `cancelPendingPhoneAuthorization` 내부 헬퍼 (`Insta360BLEController.swift`).
4. `Insta360CameraStream` 공개 메서드 + `connect(context:)` 동작 변경 (`Insta360CameraStream.swift`).
5. 단위 테스트 (`Tests/SyncFieldInsta360Tests/`).
6. `CHANGELOG.md` 항목 — 기존 톤 따름 (`### Added` / `### Changed` 섹션).
7. 새 버전 릴리즈 + 태그.

### og-skill mobile

8. `SyncFieldBridgeModule.{m,swift}` 메서드 노출.
9. `SyncFieldBridge.ts` TS 시그니처.
10. `useDeviceDiscoveryMachine.ts` 상태 확장.
11. `PhoneAuthorizationModal.tsx` 컴포넌트 (텍스트만, 일러스트 없음).
12. `DeviceDiscoveryScreen.tsx` modal 통합.
13. `recordingStartErrors.ts` 분기 + `RecordingScreen.tsx` 폴백 modal.
14. `i18n/ko.json`, `en.json` 키 추가.
15. PostHog 이벤트 계측 (`features/upload/UploadService.ts`와 동일 패턴).
16. `Podfile` syncfield-swift 신버전 의존성 업데이트 + `pod install`.

---

## 비범위 (Out of scope)

본 작업과 직교하여 별도로 다룰 항목:

- **`INSCameraSessionManagerDelegate.sessionManager:isWakeupAuth:` 통합** (`Headers/INSCameraSessionManager.h:93`) — wakeup auth 결과를 별도 surface하는 작업. Phone auth와 독립.
- **인증 만료 자동 처리** — 만료 발생 시점/조건 미확인. 운영 중 발견되면 별도 대응.
- **WiFi credentials 변경 시 재인증** — 같은 deviceId 유지로 충분 추정. 카메라 측 비밀번호 reset 등 운영 발견 시 추가.
- **ONE X3 등 다른 모델용 `checkAuthorizationWithOptions:type:`** (`Headers/INSCameraBasicCommands.h:222`) — 본 통합은 GO 3S 한정.
- **펌웨어 버전 기반 안내 분기** — 자동 throw 흐름은 본 작업, 사용자 안내 카피는 운영 데이터 보고 결정.

---

## 참조

### Insta360 SDK 헤더
- `og-skill/mobile/ios/Frameworks/Insta360/INSCameraServiceSDK.xcframework/ios-arm64/INSCameraServiceSDK.framework/Headers/INSPhoneAuthorizationStatus.h` — state enum
- `Headers/INSCameraBasicCommands.h:271-286` — `checkPhoneAuthorization` (go3)
- `Headers/INSBluetoothCommands.h:25-30` — BLE 채널 동일 시그니처
- `Headers/INSConnectionUtils.h:12-43` — initiatorType + authorizationId
- `Headers/NSNotification+INSCamera.h:357-363` — `INSPhoneAuthorizationResult`
- `Headers/INSCameraSessionManager.h:93` — isWakeupAuth 델리게이트 (future work)
- `Headers/INSBluetoothConnection.h:47` — writeWakeupAuthDataToCamera (현재 호출 중)

### syncfield-swift 통합 지점
- `Sources/SyncFieldInsta360/Insta360CameraStream.swift:103-482` — lifecycle 메서드
- `Sources/SyncFieldInsta360/Insta360Scanner.swift:210-213` — command manager ready 시점
- `Sources/SyncFieldInsta360/Insta360BLEController.swift:835-852` — 기존 wake auth 경로
- `Sources/SyncFieldInsta360/Insta360BLEController.swift:838-842` — "explicit foreground flow" 주석
- `Sources/SyncFieldInsta360/Insta360IdentityStore.swift:44` — 캐시 JSON 위치

### og-skill 통합 지점
- `mobile/src/features/recording/recordingStartErrors.ts:8-12` — 기존 에러 분류 regex
- `mobile/src/features/device/useDeviceDiscoveryMachine.ts:5-12` — 상태 머신
- `mobile/src/screens/DeviceDiscoveryScreen.tsx` — modal 통합 지점
- `mobile/src/screens/RecordingScreen.tsx:451-454` — 폴백 alert
- `mobile/ios/OGSkill/SyncField/SyncFieldBridgeModule.{m,swift}` — bridge 노출
