import AppKit
import SwiftUI

@MainActor
protocol FireworksPresenting: AnyObject {
    func show()
}

/// A click-through overlay rather than a notification: the celebration is
/// optional, brief, and must not steal focus from the terminal the user was in.
@MainActor
final class FireworksPresenter: FireworksPresenting {
    private var windows: [NSWindow] = []
    private static let displayDuration: TimeInterval = 3.4

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: FireworksOverlay())
            window.orderFrontRegardless()
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration) { [weak self] in
            self?.windows.forEach { $0.orderOut(nil) }
            self?.windows.removeAll()
        }
    }
}

private struct FireworksOverlay: View {
    private let startedAt = Date()

    var body: some View {
        // `.animation` timelines may stop ticking while another app is active —
        // exactly the ordinary menu-bar case. A wall-clock schedule keeps the
        // overlay moving over the terminal without activating Tokenmax.
        TimelineView(.periodic(from: startedAt, by: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let bursts: [(CGPoint, Double, Color)] = [
                    (.init(x: size.width * 0.16, y: size.height * 0.30), 0, .pink),
                    (.init(x: size.width * 0.43, y: size.height * 0.20), 0.28, .yellow),
                    (.init(x: size.width * 0.70, y: size.height * 0.34), 0.56, .cyan),
                    (.init(x: size.width * 0.88, y: size.height * 0.18), 0.82, .purple)
                ]
                for (origin, delay, color) in bursts {
                    let progress = min(1, max(0, (elapsed - delay) / 1.65))
                    guard progress > 0 else { continue }
                    let opacity = pow(1 - progress, 0.65)
                    for ray in 0..<28 {
                        let angle = Double(ray) / 28 * .pi * 2
                        let radius = 72 + Double(ray % 7) * 14
                        let distance = radius * progress
                        let end = CGPoint(x: origin.x + cos(angle) * distance,
                                          y: origin.y + sin(angle) * distance + progress * progress * 110)
                        let trail = CGPoint(
                            x: origin.x + cos(angle) * max(0, distance - 16),
                            y: origin.y + sin(angle) * max(0, distance - 16) + progress * progress * 110
                        )
                        var path = Path()
                        path.move(to: trail)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 2.5)
                        context.fill(
                            Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                            with: .color(.white.opacity(opacity * 0.9))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
