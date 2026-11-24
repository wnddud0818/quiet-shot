# QuietShot — iPhone 무음 카메라

Swift + SwiftUI + AVFoundation으로 만든 **네이티브 iOS 무음 카메라 앱**입니다.
지역(한국·일본 판매 모델 포함)과 관계없이 셔터음 없이 촬영하고, 기기가 허용하는 **최대 해상도**로 저장합니다.

- 지원: iOS 17 이상 (iOS 18 / 26 / 27 포함), iPhone · **iPhone Duo**(폴더블, iOS 27.1+)
- 외부 라이브러리 없음

## 무음 원리 — 두 가지 캡처 엔진 (자동 선택)

| 엔진 | 사용 조건 | 해상도 | 셔터음 |
|---|---|---|---|
| **비디오 프레임 캡처** | 기본값. 셔터음이 강제되는 기기(한국·일본 판매 모델 등), iOS 17 | 카메라 영상 스트림 최대 해상도 (대부분 **4032×3024 = 12MP**) | 없음 |
| **사진 파이프라인 + 셔터음 억제** | iOS 18+ 이고 `isShutterSoundSuppressionSupported == true` 인 기기 | 센서 최대 사진 해상도 (**48MP** / 24MP / 12MP, 기종별) | 없음 |

- **비디오 프레임 캡처**는 사진 촬영 API(`AVCapturePhotoOutput`)를 세션에 **아예 넣지 않고**,
  `AVCaptureVideoDataOutput`의 프레임을 그대로 HEIC/JPEG로 저장합니다. 시스템 셔터음은 사진 촬영 API에서만
  재생되므로 **지역과 무관하게 소리가 날 수 없는 구조**입니다.
  - 기기의 모든 카메라 포맷을 조사해 스트림 해상도가 가장 큰 포맷을 고릅니다(하드코딩 없음).
  - P3 광색역, EXIF(노출·ISO·렌즈 정보) 보존, 회전 잠금과 무관한 수평 보정을 적용합니다.
- **사진 파이프라인**은 Apple이 iOS 18에서 공개한 `AVCapturePhotoSettings.isShutterSoundSuppressionEnabled`를 사용합니다.
  Apple 문서상 셔터음 억제가 법적으로 허용되지 않는 지역의 기기에서는 이 값이 `false`이므로, 그런 기기에서는
  이 엔진이 **절대 선택되지 않습니다**. 촬영 직전에도 다시 확인하며, 지원되지 않으면 촬영하지 않고 프레임 엔진으로 전환합니다.

### 해상도에 대한 정확한 안내

한국 판매 iPhone에서 48MP 사진은 **사진 촬영 API를 통해서만** 얻을 수 있고, 그 API는 한국 모델에서 셔터음이 강제됩니다.
따라서 한국 모델에서 *무음으로* 얻을 수 있는 최대 해상도는 영상 스트림 최대 해상도(대부분 12MP, 4032×3024)입니다.
앱 상단 배지와 설정 화면에서 현재 기기의 실제 저장 해상도를 확인할 수 있습니다.

## EXIF 메타데이터

두 엔진 모두 iPhone 기본 카메라 사진과 같은 수준의 메타데이터를 파일에 기록합니다.

| 항목 | 사진 파이프라인 | 프레임 캡처 |
|---|---|---|
| 기종(Make/Model), iOS 버전(Software), 렌즈(LensMake/LensModel/LensSpecification) | Apple 파이프라인이 기록 | 프레임 첨부 값 사용, 없으면 기기 정보로 보충 |
| 초점거리·35mm 환산, 조리개(FNumber/ApertureValue), 셔터속도(ExposureTime/ShutterSpeedValue), ISO, 노출 보정, 밝기 | Apple 파이프라인이 기록 | 프레임 첨부 값 사용, 없으면 촬영 순간의 카메라 상태로 보충 |
| 측광·노출 모드·화이트밸런스·플래시·디지털 줌·장면 유형·피사체 영역 | Apple 파이프라인이 기록 | 동일 |
| 촬영 일시(DateTimeOriginal/Digitized, 1/1000초, 시간대 OffsetTime) | Apple 파이프라인이 기록 | 기록 |
| 해상도(PixelX/YDimension), 방향, 색 공간 + ICC 프로파일(Display P3/sRGB) | 기록 | 기록 |
| Apple 제조사 정보(`{MakerApple}`) | 기록 | 프레임에 첨부된 경우 그대로 기록 |
| **GPS** 위도·경도·고도·정확도·속도·촬영 방향·UTC 시각 | 앱이 추가 기록 | 앱이 추가 기록 |
| 내장 썸네일 | 기록 | 기록 |

- GPS는 설정의 **촬영 위치(GPS) 기록**으로 끌 수 있습니다(기본 켜짐, 위치 권한 필요). 사진 앱의 지도/장소 정보에도 반영됩니다.
- 위치 정보는 카메라가 화면에 떠 있는 동안에만 갱신하며, 10분 이상 지난 위치는 기록하지 않습니다.

## 기능

**촬영**
- 셔터 탭: 1장 촬영 / **길게 누르기: 손 뗄 때까지 연속 촬영**
- **볼륨 버튼 · 카메라 제어 버튼(iPhone 16+) · AirPods**로도 촬영 (AirPods 촬영음도 끔)
- **셀프 타이머** 3초 / 10초 — 소리 없이 화면 카운트다운, 셔터를 다시 누르면 취소
- 소리 대신 화면 깜빡임 + (선택) 햅틱으로 촬영 피드백

**줌**
- 후면은 멀티 렌즈 가상 카메라로 **0.5× → 1× → 2× → 3×/5×가 끊김 없이** 이어짐
- 줌 버튼 탭 / 버튼 줄을 **좌우로 끌면 줌 다이얼** / 핀치 / 카메라 제어 버튼 슬라이더
- **전면 카메라 0.8×(넓게, 센서 전체) · 1×(표준)** 전환, 마지막 선택 기억
- iPhone 17 이후의 정사각형 센서 Center Stage 전면 카메라 지원

**초점 · 노출**
- 탭: 초점/노출 → 표시가 떠 있을 때 **위아래로 끌면 노출(±2EV)** 조절 (해 아이콘)
- **길게 누르기: AE/AF 잠금**

**빠른 설정**
- 상단 배지(무음 · 해상도)를 누르거나 **미리보기를 위로 쓸어 올리면** 비율 / 타이머 / 격자 / HEIC·JPEG
- **촬영 비율 4:3 / 3:2 / 16:9 / 1:1** — iPhone 기본 카메라처럼 센서 전체 이미지를 중앙 크롭, 미리보기 영역 그대로 저장
  (예: 12MP 센서 → 4:3 12MP, 3:2 10MP, 16:9·1:1 9MP / 48MP 사진 파이프라인 → 16:9 36MP)
- 전면/후면 전환 시 뒤집기 애니메이션, 새 사진 썸네일 애니메이션, 민트색 포인트 디자인

**iPhone Duo (폴더블) 전용 화면**
- **반쯤 접으면(탁상·책 모드)** 접는 선을 기준으로 한쪽은 미리보기, 다른 쪽은 큰 셔터와 조작부로 나뉨 —
  테이블에 세워 두고 셀프 타이머·볼륨 버튼으로 찍기 좋음 (`onHingeChange`, `reservedRegions(kind: .division)`)
- **펼친 안쪽 화면**: 큰 미리보기 + 빠른 설정이 항상 보이는 패널, 큰 셔터. 가로로 돌려도 맞춰 배치
- **바깥 화면 미리보기**: 펼쳐서 찍을 때 바깥 화면에 실시간 미리보기·카운트다운·촬영 깜빡임을 띄워
  찍히는 사람이 자기 모습을 확인 (후면 카메라 셀카에 유용, `CameraCaptureAccessory`, 빠른 설정에서 켜고 끔)
- 안쪽 화면 **카메라 구멍(화면 아래 카메라) 영역을 피해** 버튼 배치 (`reservedRegions(kind: .occlusion)`)
- 접으면 **바깥 화면 카메라**, 펼치면 **안쪽 화면 카메라** 등 사용자를 향한 전면 카메라로 자동 전환
  (`AVCaptureDeviceDirectionCoordinator`; 1080p로 제한되는 가상 전면 카메라 대신 개별 카메라 사용)

**저장**
- HEIC / JPEG, 전면 카메라 좌우 반전 저장, 격자, 햅틱(기본 꺼짐 — 조용한 곳에서 진동음이 들릴 수 있음)
- 사진 보관함에는 "사진 추가 전용" 권한만 사용

## IPA 다운로드

- 최신 빌드(서명 안 됨): **[QuietShot-unsigned.ipa](https://github.com/wnddud0818/quiet-shot/releases/latest/download/QuietShot-unsigned.ipa)**
  (모든 빌드: [Releases](https://github.com/wnddud0818/quiet-shot/releases))
- 서명되지 않은 IPA라 그대로는 설치되지 않습니다. PC/Mac에서 **Sideloadly** 또는 **AltStore**에 IPA를 넣고 본인 Apple ID로 서명해 설치하세요
  (무료 Apple ID는 7일마다 재설치, 유료 개발자 계정은 1년). iPhone에서 *설정 > 개인정보 보호 및 보안 > 개발자 모드*를 켜야 합니다.
- `main`에 푸시할 때마다 GitHub Actions가 새 IPA를 만들어 Releases에 올립니다.

## 빌드 & 설치

1. Mac에서 **Xcode 26 이상**으로 `QuietShot.xcodeproj`를 엽니다. **iPhone Duo 기능은 Xcode 27.1 이상**으로 빌드해야 포함됩니다
   (더 낮은 Xcode에서는 Duo 전용 코드만 빠지고 나머지는 그대로 빌드됩니다).
2. 타깃 **QuietShot → Signing & Capabilities**
   - Team: 본인 Apple ID 팀 선택
   - Bundle Identifier: `com.quietshot.camera` → 본인 고유 값으로 변경 (예: `com.yourname.quietshot`)
3. iPhone을 연결하고 실행 (▶). 카메라는 **실기기에서만** 동작합니다(시뮬레이터 불가).
4. 처음 실행 시 iPhone에서 *설정 > 개인정보 보호 및 보안 > 개발자 모드*가 필요할 수 있습니다.

CI(GitHub Actions, `.github/workflows/ios-build.yml`)가 푸시할 때마다 **Xcode 26(iOS 26 SDK)과 Xcode 27(iOS 27 SDK)** 두 환경에서 서명 없이 빌드를 검증합니다.

## 구조

```
QuietShot/
├─ App/QuietShotApp.swift              앱 진입점
├─ Camera/
│  ├─ CameraController.swift           세션 구성, 엔진 선택, 무음 캡처 (핵심)
│  ├─ FormatSelector.swift             최대 해상도 포맷 선택
│  ├─ ZoomModel.swift                  줌 버튼·배율 계산 (후면 가상 카메라, 전면 넓게/표준)
│  ├─ DuoSupport.swift                 iPhone Duo 전용 API (iOS 27.1 SDK에서만 컴파일)
│  └─ PhotoCaptureProcessor.swift      사진 파이프라인 델리게이트
├─ Support/
│  ├─ ImageEncoder.swift               HEIC/JPEG 인코딩 + EXIF
│  ├─ PhotoLibrarySaver.swift          사진 보관함 저장
│  ├─ MetadataBuilder.swift            EXIF/TIFF/GPS 메타데이터
│  ├─ LocationProvider.swift           GPS 위치·방향
│  ├─ DeviceOrientationMonitor.swift   아이콘 회전용 기기 방향
│  └─ Settings.swift                   설정 키 / 저장 형식 / 비율 / 타이머
└─ Views/                              SwiftUI 화면 (CameraScreen, ZoomControl, FocusOverlay, QuickControls …)
```

## 참고

- 미리보기는 `AVCaptureVideoPreviewLayer` 대신 **비디오 프레임을 직접 그립니다**(`AVSampleBufferDisplayLayer`).
  정사각형 전면 센서(iPhone 17·Duo)에서도 찌그러지지 않고, 저장되는 프레임과 똑같은 화면이 보이며,
  iPhone Duo 바깥 화면에도 같은 프레임을 보냅니다.
- 기기에서 문제가 생기면 **설정 > 진단 정보** 화면을 캡처해 주세요 (카메라 종류, 포맷, 회전 각도, 동적 비율 등).

- 비디오 프레임 캡처는 사진 파이프라인의 다중 프레임 합성(Deep Fusion, Smart HDR) 대신 영상 처리 파이프라인을 거친 단일 프레임이라,
  저조도에서는 기본 카메라 앱보다 노이즈가 많을 수 있습니다.
- App Store 배포 시 심사 지침과 각국 법규를 확인하세요. 타인을 동의 없이 촬영하는 용도로 사용해서는 안 됩니다.
