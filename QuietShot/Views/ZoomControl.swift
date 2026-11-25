import SwiftUI

/// 줌 버튼 줄 + 좌우로 끌면 나타나는 줌 다이얼.
/// - 버튼 탭: 해당 배율로 부드럽게 이동 (선택된 버튼에는 현재 배율 표시)
/// - 버튼 줄을 좌우로 드래그: 다이얼이 펼쳐지며 연속 줌 (왼쪽으로 끌면 확대)
/// - 다이얼 햅틱: 눈금마다 틱, 렌즈 배율에서 탭, 끝에 닿으면 단단한 탭
struct ZoomControl: View {
    let configuration: ZoomConfiguration
    let displayZoom: CGFloat
    let iconAngle: Angle
    var showsFixedZoom = false
    /// 녹화 중에는 진동 소리가 마이크에 담기지 않도록 끈다.
    var hapticsEnabled = true
    let onSelect: (ZoomPreset) -> Void
    let onContinuousZoom: (CGFloat) -> Void

    @State private var dialVisible = false
    @State private var dragStartDisplay: CGFloat?
    /// 다이얼을 끄는 동안 직전 배율 (햅틱 눈금 비교용)
    @State private var lastValue: CGFloat?
    @State private var hideTask: Task<Void, Never>?
    /// 다이얼을 끌고 손을 뗄 때 그 아래 버튼이 눌린 것으로 처리되어 배율이 튀는 것을 막기 위함
    @State private var lastDragEnd = Date.distantPast

    /// 드래그 거리 → 배율 감도 (이만큼 끌면 2배). 사이 배율을 고르기 쉽도록 넉넉하게
    private let pointsPerDoubling: CGFloat = 130

    private var minDisplay: CGFloat { configuration.display(for: configuration.minFactor) }
    private var maxDisplay: CGFloat { configuration.display(for: configuration.maxFactor) }

    var body: some View {
        VStack(spacing: 6) {
            if dialVisible {
                ZoomDial(
                    value: displayZoom,
                    minValue: minDisplay,
                    maxValue: maxDisplay,
                    presets: configuration.presets.map(\.display),
                    iconAngle: iconAngle,
                    pointsPerDoubling: pointsPerDoubling
                )
                .frame(height: 78)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            presetRow
        }
        .animation(.easeOut(duration: 0.2), value: dialVisible)
    }

    @ViewBuilder
    private var presetRow: some View {
        let presets = configuration.presets
        if presets.count > 1 || maxDisplay > minDisplay + 0.01 {
            HStack(spacing: 6) {
                if presets.isEmpty {
                    chip(title: ZoomPreset.format(displayZoom) + "×", selected: true)
                } else {
                    ForEach(presets) { preset in
                        let selected = preset.id == selectedPreset?.id
                        Button {
                            // 다이얼을 끄는 중이거나 방금 놓았으면 무시 (사이 배율 유지)
                            guard dragStartDisplay == nil, Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
                            if hapticsEnabled { ZoomDialHaptics.shared.tick() }
                            onSelect(preset)
                        } label: {
                            chip(title: selected ? ZoomPreset.format(displayZoom) + "×" : preset.label, selected: selected)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("\(preset.label)배 줌")
                    }
                }
            }
            .padding(4)
            .background(Capsule().fill(Theme.glass))
            .contentShape(Capsule())
            .simultaneousGesture(dialDrag)
        } else if showsFixedZoom {
            chip(title: ZoomPreset.format(displayZoom) + "×", selected: true)
                .padding(4)
                .background(Capsule().fill(Theme.glass))
                .accessibilityLabel("고정 화각")
                .accessibilityValue("\(ZoomPreset.format(displayZoom))배")
                .allowsHitTesting(false)
        }
    }

    /// 현재 배율이 속한 구간의 버튼 (예: 1.4× → "1" 버튼)
    private var selectedPreset: ZoomPreset? {
        let presets = configuration.presets
        return presets.last(where: { $0.display <= displayZoom + 0.05 }) ?? presets.first
    }

    private func chip(title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: selected ? 13 : 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(selected ? Theme.accent : Color.white)
            .frame(width: selected ? 42 : 34, height: selected ? 42 : 34)
            .background(Circle().fill(Color.white.opacity(selected ? 0.16 : 0.08)))
            .rotationEffect(iconAngle)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }

    private var dialDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                hideTask?.cancel()
                if dragStartDisplay == nil {
                    dragStartDisplay = displayZoom
                    lastValue = displayZoom
                    dialVisible = true
                    if hapticsEnabled { ZoomDialHaptics.shared.prepare() }
                }
                let start = dragStartDisplay ?? displayZoom
                let target = start * pow(2, -value.translation.width / pointsPerDoubling)
                let clamped = min(max(target, minDisplay), maxDisplay)
                if hapticsEnabled { dialFeedback(from: lastValue ?? start, to: clamped) }
                lastValue = clamped
                onContinuousZoom(clamped)
            }
            .onEnded { _ in
                lastDragEnd = Date()
                dragStartDisplay = nil
                hideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    guard !Task.isCancelled else { return }
                    dialVisible = false
                }
            }
    }

    /// 렌즈 배율(0.5, 1, 2, 5…)을 지나면 탭, 최소·최대 배율에 닿으면 단단한 탭,
    /// 그 밖에는 다이얼에 그려진 작은 눈금(1/8 스톱)을 지날 때마다 가벼운 틱.
    private func dialFeedback(from previous: CGFloat, to value: CGFloat) {
        guard previous != value else { return }
        let haptics = ZoomDialHaptics.shared
        if configuration.presets.contains(where: { crosses($0.display, from: previous, to: value) }) {
            haptics.detent()
        } else if (value <= minDisplay || value >= maxDisplay) && previous > minDisplay && previous < maxDisplay {
            haptics.limit()
        } else if tickIndex(previous) != tickIndex(value) {
            haptics.tick()
        }
    }

    /// ZoomDial이 최소 배율부터 1/8 스톱 간격으로 그리는 눈금 번호
    private func tickIndex(_ value: CGFloat) -> Int {
        Int(((log2(max(value, 0.01)) - log2(minDisplay)) * 8 + 0.0001).rounded(.down))
    }

    private func crosses(_ detent: CGFloat, from: CGFloat, to: CGFloat) -> Bool {
        (from < detent && to >= detent) || (from > detent && to <= detent)
    }
}

/// 로그 눈금 줌 다이얼 (가운데가 현재 배율)
struct ZoomDial: View {
    let value: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat
    let presets: [CGFloat]
    let iconAngle: Angle
    let pointsPerDoubling: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            // 현재 배율 (마스크 밖에 두어 잘리지 않게)
            Text(ZoomPreset.format(value) + "×")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .rotationEffect(iconAngle)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .fixedSize()

            ruler
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .background(Capsule().fill(Color.black.opacity(0.35)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ruler: some View {
        Canvas { context, size in
            let center = size.width / 2
            let baseline = size.height - 6
            let current = log2(max(value, 0.01))

            func x(_ v: CGFloat) -> CGFloat {
                center + (log2(v) - current) * pointsPerDoubling
            }

            // 작은 눈금: 1/8 스톱 간격
            var stop = log2(minValue)
            let end = log2(maxValue)
            while stop <= end + 0.0001 {
                let px = x(pow(2, stop))
                if px > -4 && px < size.width + 4 {
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: baseline))
                    tick.addLine(to: CGPoint(x: px, y: baseline - 8))
                    context.stroke(tick, with: .color(.white.opacity(0.45)), lineWidth: 1)
                }
                stop += 0.125
            }

            // 렌즈 배율 눈금 + 라벨
            for preset in presets {
                let px = x(preset)
                guard px > -20 && px < size.width + 20 else { continue }
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: baseline))
                tick.addLine(to: CGPoint(x: px, y: baseline - 16))
                context.stroke(tick, with: .color(.white), lineWidth: 1.5)
                var labelContext = context
                labelContext.translateBy(x: px, y: baseline - 26)
                labelContext.rotate(by: iconAngle)
                labelContext.draw(
                    Text(ZoomPreset.format(preset))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white),
                    at: .zero
                )
            }

            // 가운데 기준선
            var marker = Path()
            marker.move(to: CGPoint(x: center, y: baseline + 2))
            marker.addLine(to: CGPoint(x: center, y: baseline - 22))
            context.stroke(marker, with: .color(Theme.accent), lineWidth: 2)
        }
    }
}
