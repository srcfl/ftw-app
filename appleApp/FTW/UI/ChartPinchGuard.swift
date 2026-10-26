import SwiftUI
import UIKit

/// Keeps a two-finger pinch on a chart for the chart.
///
/// A view that zooms in from its source (`navigationTransition(.zoom)`)
/// can be pinched closed by the system, and on a chart that pinch closed
/// the whole view instead of zooming time (Fredrik, 26 October 2026). This
/// recognizer only watches and never acts. It recognises a pinch together
/// with the chart's own gesture, and the system's pinch above it waits for
/// it to fail, which it does when no second finger lands. A back swipe and
/// a scroll keep their own way, and a pinch outside the chart still
/// closes the view.
///
/// The one UIKit piece outside the camera: SwiftUI has no say over the
/// transition's own gesture.
struct ChartPinchGuard: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let pinch = UIPinchGestureRecognizer()
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        pinch.delegate = context.coordinator
        return pinch
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Self.closes(other, above: g)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.closes(other, above: g)
        }

        /// A pinch on a view that holds the chart: the transition's, which
        /// would close the view.
        static func closes(_ other: UIGestureRecognizer, above g: UIGestureRecognizer) -> Bool {
            guard other is UIPinchGestureRecognizer, let mine = g.view, let theirs = other.view, mine !== theirs else { return false }
            return mine.isDescendant(of: theirs)
        }
    }
}
