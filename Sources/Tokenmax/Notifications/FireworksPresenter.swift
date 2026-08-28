import AppKit
import SwiftUI

/// A click-through overlay rather than a notification: the celebration is
/// optional, brief, and must not steal focus from the terminal the user was in.
@MainActor
final class FireworksPresenter {
    private var windows: [NSWindow] = []

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.windows.forEach { $0.orderOut(nil) }
            self?.windows.removeAll()
        }
    }
}

private struct FireworksOverlay: View {
    private let startedAt = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let bursts: [(CGPoint, Double, Color)] = [
                    (.init(x: size.width * 0.18, y: size.height * 0.30), 0, .pink),
                    (.init(x: size.width * 0.52, y: size.height * 0.20), 0.22, .yellow),
                    (.init(x: size.width * 0.81, y: size.height * 0.36), 0.42, .cyan)
                ]
                for (origin, delay, color) in bursts {
                    let progress = min(1, max(0, (elapsed - delay) / 1.25))
                    guard progress > 0 else { continue }
                    for ray in 0..<28 {
                        let angle = Double(ray) / 28 * .pi * 2
                        let distance = (45 + Double(ray % 7) * 11) * progress
                        let end = CGPoint(x: origin.x + cos(angle) * distance,
                                          y: origin.y + sin(angle) * distance + progress * progress * 110)
                        var path = Path()
                        path.move(to: origin)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(color.opacity((1 - progress) * 0.9)), lineWidth: 2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
