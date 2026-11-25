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
            print("Duo capture control placement checks passed")
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
