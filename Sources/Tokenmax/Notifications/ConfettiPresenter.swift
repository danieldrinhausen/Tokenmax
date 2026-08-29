import AppKit
import SwiftUI

@MainActor
protocol ConfettiPresenting: AnyObject {
    func show()
}

/// A click-through overlay rather than a notification: the celebration is
/// optional, brief, and must not steal focus from the terminal the user was in.
@MainActor
final class ConfettiPresenter: ConfettiPresenting {
    private var windows: [NSWindow] = []
    private static let displayDuration: TimeInterval = 4.2

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: ConfettiOverlay())
            window.orderFrontRegardless()
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration) { [weak self] in
            self?.windows.forEach { $0.orderOut(nil) }
            self?.windows.removeAll()
        }
    }
}

private struct ConfettiOverlay: View {
    private let startedAt = Date()
    private let colors: [Color] = [
        .pink, .yellow, .cyan, .purple, .orange, .green,
        Color(red: 0.25, green: 0.45, blue: 1),
        Color(red: 1, green: 0.25, blue: 0.32)
    ]

    var body: some View {
        // `.animation` timelines may stop ticking while another app is active —
        // exactly the ordinary menu-bar case. A wall-clock schedule keeps the
        // overlay moving over the terminal without activating Tokenmax.
        TimelineView(.periodic(from: startedAt, by: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let area = size.width * size.height
                let count = min(280, max(160, Int(area / 7_000)))

                for index in 0..<count {
                    let fallDuration = 2.8 + unit(index, salt: 1) * 1.8
                    let phase = unit(index, salt: 2)
                    let progress = (elapsed / fallDuration + phase)
                        .truncatingRemainder(dividingBy: 1)
                    let drift = 10 + unit(index, salt: 3) * 34
                    let frequency = 1.1 + unit(index, salt: 4) * 2.2
                    let x = unit(index, salt: 5) * size.width
                        + sin(elapsed * frequency + phase * .pi * 2) * drift
                    let y = -24 + progress * (size.height + 48)
                    let width = 5 + unit(index, salt: 6) * 6
                    let height = 9 + unit(index, salt: 7) * 10
                    let rotation = elapsed * (2 + unit(index, salt: 8) * 7)
                        + phase * .pi * 2
                    let edgeFade = min(1, (1 - progress) / 0.08)
                    let entranceFade = min(1, elapsed / 0.18)

                    var particle = context
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(rotation))
                    let rect = CGRect(
                        x: -width / 2, y: -height / 2,
                        width: width, height: height
                    )
                    let path = index.isMultiple(of: 9)
                        ? Path(ellipseIn: rect)
                        : Path(rect)
                    particle.fill(
                        path,
                        with: .color(colors[index % colors.count].opacity(edgeFade * entranceFade))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Stable pseudo-randomness: every frame must put the same particle on the
    /// same trajectory, or the shower flickers instead of falling.
    private func unit(_ index: Int, salt: Double) -> Double {
        let value = sin(Double(index + 1) * 12.9898 + salt * 78.233) * 43_758.5453
        return value - floor(value)
    }
}
