import SwiftUI

@main
enum DuoCaptureControlsTests {
    @MainActor
    static func main() {
        if #available(macOS 13.0, *) {
            check(width: 360, height: 750, landscape: false)
            check(width: 750, height: 360, landscape: true)
            check(width: 720, height: 800, landscape: false)
            check(width: 800, height: 720, landscape: true)
            check(width: 640, height: 245, landscape: false, separateLenses: true)
            check(width: 330, height: 640, landscape: true, separateLenses: true)
            check(width: 225, height: 580, landscape: false, separateLenses: true)
            checkTurns(size: CGSize(width: 390, height: 820), closed: true)
            let inner = CGSize(width: 740, height: 680)
            checkTurns(size: inner, closed: false)
            let hinge = CGRect(x: 355, y: 0, width: 12, height: inner.height)
            for entry in [0.0, 90, -90, 180] {
                checkTurns(size: inner, closed: false, fold: hinge, entry: entry)
            }
            print("Duo capture control placement checks passed")
        }
    }

    // UIKit 창에 보이는 물리적 사각형. 구현의 행렬과 독립적으로 네 방향의 기대값을 만든다.
    static func sceneRect(_ r: CGRect, screen: CGSize, degrees: Double) -> CGRect {
        switch degrees {
        case 90:
            return CGRect(x: r.minY, y: screen.width - r.maxX, width: r.height, height: r.width)
        case -90:
            return CGRect(x: screen.height - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 180:
            return CGRect(x: screen.width - r.maxX, y: screen.height - r.maxY, width: r.width, height: r.height)
        default: return r
        }
    }

    @available(macOS 13.0, *)
    @MainActor
    static func checkTurns(size: CGSize, closed: Bool, fold: CGRect? = nil, entry: Double = 0) {
        var anchor: DuoControlSpace.Anchor?
        var physicalButtons: [String: CGRect] = [:]
        var physicalPreview: CGRect?
        for degrees in [entry, 90, 180, -90, 0] {
            let bounds = sceneRect(CGRect(origin: .zero, size: size), screen: size, degrees: degrees)
            // 홈 인디케이터 여백은 회전할 때마다 창 아래에 생긴다.
            let safe = CGRect(x: 4, y: 18, width: bounds.width - 12, height: bounds.height - 48)
            let space = DuoControlSpace(sceneSize: bounds.size, safeBounds: safe, sceneDegrees: degrees,
                                        posture: closed ? .closed : (fold == nil ? .open : .folded),
                                        sceneFold: fold.map { sceneRect($0, screen: size, degrees: degrees) },
                                        previous: anchor)
            if let anchor { precondition(space.anchor == anchor) }
            anchor = space.anchor
            precondition(space.split == (fold != nil))
            precondition(space.sideRail == (!closed && (fold == nil || abs(entry) != 90)))
            for motion in [0.0, 90, -90, 180] {
                let screenGlyph = space.labelDegrees(for: motion) - space.sceneDegrees
                precondition((screenGlyph - (motion - degrees)).truncatingRemainder(dividingBy: 360) == 0)
            }
            var buttons: [String: CGRect] = [:]
            func button(_ id: String, _ width: CGFloat, _ height: CGFloat) -> some View {
                GeometryReader { proxy in
                    let _ = buttons[id] = proxy.frame(in: .named("scene"))
                    Color.white
                }.frame(width: width, height: height)
            }
            let controls = DuoCaptureControls(landscape: space.sideRail, railWidth: 96,
                                             tools: EmptyView(), lenses: Group { if !space.split { button("zoom", 166, 50) } },
                                             modes: button("mode", 92, 44), shutter: button("shutter", 78, 78),
                                             gallery: button("gallery", 52, 52), flip: button("flip", 52, 52))
                .frame(width: space.controls.width, height: space.controls.height)
                .position(x: space.controls.midX, y: space.controls.midY)
                .modifier(DuoControlPlacement(space: space))
                .frame(width: bounds.width, height: bounds.height)
                .coordinateSpace(name: "scene")
            precondition(ImageRenderer(content: controls).cgImage != nil && buttons.count == (space.split ? 4 : 5))
            for (id, frame) in buttons {
                if let original = physicalButtons[id] {
                    let expected = sceneRect(original, screen: size, degrees: degrees)
                    precondition(abs(frame.midX - expected.midX) <= 1 && abs(frame.midY - expected.midY) <= 1)
                } else {
                    physicalButtons[id] = sceneRect(frame, screen: bounds.size, degrees: degrees == 180 ? 180 : -degrees)
                }
            }
            let preview = space.viewfinder.applying(space.fixedToScene)
            if let physicalPreview {
                precondition(preview == sceneRect(physicalPreview, screen: size, degrees: degrees))
            } else {
                physicalPreview = sceneRect(preview, screen: bounds.size, degrees: degrees == 180 ? 180 : -degrees)
            }
        }
    }

    @available(macOS 13.0, *)
    @MainActor
    static func check(width: CGFloat, height: CGFloat, landscape: Bool, separateLenses: Bool = false) {
        var frames: [String: CGRect] = [:]
        func probe(_ name: String, _ width: CGFloat?, _ height: CGFloat) -> some View {
            GeometryReader { proxy in
                let _ = frames[name] = proxy.frame(in: .named("capture"))
                Color.white
            }
            .frame(width: width, height: height)
        }
        let controls = DuoCaptureControls(
            landscape: landscape, railWidth: 96,
            tools: Group { if !separateLenses { probe("tools", nil, 44) } },
            lenses: Group { if !separateLenses { probe("lenses", 166, 50) } },
            modes: probe("modes", 92, 44),
            shutter: probe("shutter", 78, 78),
            gallery: probe("gallery", 52, 52),
            flip: probe("flip", 52, 52)
        )
        .frame(width: width, height: height)
        .coordinateSpace(name: "capture")
        let renderer = ImageRenderer(content: controls)
        precondition(renderer.cgImage != nil)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let shutter = frames["shutter"], let gallery = frames["gallery"],
              let flip = frames["flip"], let modes = frames["modes"] else {
            preconditionFailure("Missing shooting controls")
        }
        for frame in frames.values { precondition(bounds.contains(frame)) }
        if landscape {
            precondition(abs(shutter.midX - (width - 48)) <= 1 && abs(shutter.midY - height / 2) <= 1)
            precondition(flip.maxY < shutter.minY && gallery.minY > shutter.maxY)
            precondition(modes.maxY >= height - 12 && modes.maxX < shutter.minX)
        } else {
            precondition(abs(shutter.midX - width / 2) <= 1 && shutter.maxY >= height - 12)
            precondition(gallery.minX <= 14 && flip.maxX >= width - 14)
            precondition(gallery.maxX < shutter.minX && shutter.maxX < flip.minX && modes.maxY <= shutter.minY)
        }
        if !separateLenses {
            guard let lenses = frames["lenses"], let tools = frames["tools"] else {
                preconditionFailure("Missing default camera controls")
            }
            precondition(tools.minY <= 12)
            precondition(lenses.maxY <= modes.minY && modes.minY - lenses.maxY <= 6)
        }
    }
}
