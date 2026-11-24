import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.saveFormat) private var saveFormat: SaveFormat = .heic
    @AppStorage(SettingsKey.mirrorFrontCamera) private var mirrorFrontCamera = false
    @AppStorage(SettingsKey.showGrid) private var showGrid = false
    @AppStorage(SettingsKey.hapticOnCapture) private var hapticOnCapture = false
    @AppStorage(SettingsKey.forceFrameEngine) private var forceFrameEngine = false
    @AppStorage(SettingsKey.saveLocation) private var saveLocation = true
    @AppStorage(SettingsKey.aspectRatio) private var aspectRatio: AspectRatioOption = .fourThree
    @AppStorage(SettingsKey.captureTimer) private var captureTimer: CaptureTimer = .off

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("카메라", value: camera.cameraLabel)
                    LabeledContent("저장 해상도", value: camera.resolutionText(for: aspectRatio))
                    LabeledContent("캡처 방식", value: camera.engine.title)
                    LabeledContent("셔터음", value: "없음 (무음)")
                    Text(engineExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("현재 카메라")
                }

                Section {
                    Picker("촬영 비율", selection: $aspectRatio) {
                        ForEach(AspectRatioOption.allCases) { option in
                            Text("\(option.title) (\(camera.megapixelText(for: option)))").tag(option)
                        }
                    }
                    Picker("파일 형식", selection: $saveFormat) {
                        ForEach(SaveFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    Toggle("전면 카메라 좌우 반전 저장", isOn: $mirrorFrontCamera)
                } header: {
                    Text("저장")
                }

                Section {
                    Toggle("촬영 위치(GPS) 기록", isOn: $saveLocation)
                    if saveLocation && LocationProvider.shared.isAuthorizationDenied {
                        Button("위치 권한이 꺼져 있습니다 — 설정 열기") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("EXIF 메타데이터")
                } footer: {
                    Text("기종·렌즈, 초점거리(35mm 환산 포함), 조리개, 셔터속도, ISO, 노출 보정, 측광·화이트밸런스, 디지털 줌, 촬영 일시(시간대·1/1000초 포함), 해상도, 색 공간과 Apple 제조사 정보(MakerApple)를 기록합니다. 위치 기록을 켜면 GPS 위도·경도·고도·촬영 방향도 기록됩니다.")
                }

                Section {
                    Picker("셀프 타이머", selection: $captureTimer) {
                        ForEach(CaptureTimer.allCases) { timer in
                            Text(timer.title).tag(timer)
                        }
                    }
                    Toggle("격자 표시", isOn: $showGrid)
                    Toggle("햅틱 피드백", isOn: $hapticOnCapture)
                    if camera.shutterSuppressionSupported {
                        Toggle("항상 프레임 캡처 사용", isOn: $forceFrameEngine)
                            .onChange(of: forceFrameEngine) { _, _ in
                                camera.reconfigure()
                            }
                    }
                } header: {
                    Text("촬영")
                } footer: {
                    Text("셔터: 탭하면 촬영, 길게 누르면 연속 촬영. 볼륨 버튼·카메라 제어 버튼으로도 촬영할 수 있습니다.\n미리보기: 탭하면 초점, 길게 누르면 AE/AF 잠금, 초점 표시 후 위아래로 끌면 노출 조절, 위로 쓸어 올리면 빠른 설정.\n줌: 버튼을 탭하거나 좌우로 끌면 다이얼이 나타납니다. 전면 카메라는 0.8(넓게)·1×(표준)를 지원합니다.\n햅틱은 조용한 곳에서 진동음이 들릴 수 있어 기본으로 꺼져 있습니다.")
                }

                Section {
                    ForEach(camera.diagnostics, id: \.self) { line in
                        Text(line)
                    }
                    Text("미리보기 프레임: \(Int(camera.previewFrameSize.width))×\(Int(camera.previewFrameSize.height)) · 회전 \(Int(camera.previewRotationAngle))° (표시 \(Int(camera.previewDisplayAngle))°)")
                } header: {
                    Text("진단 정보")
                } footer: {
                    Text("문제가 있으면 이 화면을 캡처해서 알려 주세요.")
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private var engineExplanation: String {
        switch camera.engine {
        case .photoPipeline:
            return "이 기기는 iOS의 셔터음 억제 기능이 허용되어, 정식 사진 처리(Deep Fusion·Smart HDR)를 거친 센서 최대 해상도 사진을 무음으로 촬영합니다."
        case .videoFrame:
            if camera.shutterSuppressionSupported {
                return "설정에 따라 카메라 영상 스트림의 프레임을 그대로 저장합니다. 사진 촬영 API를 쓰지 않으므로 셔터음이 원천적으로 발생하지 않습니다."
            }
            return "이 기기는 시스템 셔터음이 강제되는 기기(한국·일본 판매 모델 등)이거나 iOS 17이므로, 카메라 영상 스트림의 프레임을 그대로 저장합니다. 사진 촬영 API를 쓰지 않아 지역과 관계없이 셔터음이 발생하지 않으며, 기기가 영상 스트림으로 제공하는 최대 해상도로 저장됩니다."
        }
    }
}
