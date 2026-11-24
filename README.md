# QuietShot — iPhone 무음 카메라

Swift + SwiftUI + AVFoundation으로 만든 **네이티브 iOS 무음 카메라 앱**입니다.
지역(한국·일본 판매 모델 포함)과 관계없이 셔터음 없이 촬영하고, 기기가 허용하는 **최대 해상도**로 저장합니다.

- 지원: iOS 17 이상 (iOS 18 / 26 / 27 포함), iPhone
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

## 기능

- 탭: 1장 촬영 / **길게 누르기: 연속 촬영** (손 뗄 때까지)
- 후면 렌즈 전환(0.5× / 1× / 망원) — 렌즈마다 별도 물리 카메라를 사용해 렌즈별 최대 해상도 유지
- 핀치 줌, 탭 초점/노출, 손전등, 전면/후면 전환
- HEIC / JPEG 선택, 전면 카메라 좌우 반전 저장, 격자, 촬영 진동(기본 꺼짐)
- 촬영 피드백은 소리 대신 화면 깜빡임
- 사진 보관함에는 "사진 추가 전용" 권한만 사용

## 빌드 & 설치

1. Mac에서 **Xcode 16 이상**(iOS 27용은 Xcode 27 권장)으로 `QuietShot.xcodeproj`를 엽니다.
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
│  ├─ LensOption.swift                 후면 렌즈 탐색/배율 계산
│  └─ PhotoCaptureProcessor.swift      사진 파이프라인 델리게이트
├─ Support/
│  ├─ ImageEncoder.swift               HEIC/JPEG 인코딩 + EXIF
│  ├─ PhotoLibrarySaver.swift          사진 보관함 저장
│  ├─ DeviceOrientationMonitor.swift   아이콘 회전용 기기 방향
│  └─ Settings.swift                   설정 키 / 저장 형식
└─ Views/                              SwiftUI 화면
```

## 참고

- 비디오 프레임 캡처는 사진 파이프라인의 다중 프레임 합성(Deep Fusion, Smart HDR) 대신 영상 처리 파이프라인을 거친 단일 프레임이라,
  저조도에서는 기본 카메라 앱보다 노이즈가 많을 수 있습니다.
- App Store 배포 시 심사 지침과 각국 법규를 확인하세요. 타인을 동의 없이 촬영하는 용도로 사용해서는 안 됩니다.
