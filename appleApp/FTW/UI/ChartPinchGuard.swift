import SwiftUI
import UIKit

/// Keeps a pinch on a chart for the chart.
///
/// A view that zooms in from its source (`navigationTransition(.zoom)`)
/// can be pinched closed by the system, and on a chart that pinch closed
/// the whole view instead of zooming time (Fredrik, 26 October 2026). This
/// pinch recognizer only watches: it recognises together with the chart's
/// own gesture, and the transition's gesture has to wait for it to fail,
/// which it does when no second finger lands. On iOS 26 that gesture is a
/// private transform recognizer on the navigation stack's hosting view,
/// the same view SwiftUI hangs this one on (seen in the simulator). A back
/// swipe from the edge and a pinch outside the chart keep their way.
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

        /// The transition's pinch to close: on this view or one above it,
        /// a pinch, or iOS 26's private transform recognizer. The name is a
        /// deliberate dependency; if a later iOS renames it, the old fault
        /// comes back and nothing else breaks.
        static func closes(_ other: UIGestureRecognizer, above g: UIGestureRecognizer) -> Bool {
            guard other !== g, let mine = g.view, let theirs = other.view, mine.isDescendant(of: theirs) else { return false }
            return other is UIPinchGestureRecognizer || String(describing: type(of: other)).contains("TransformGesture")
        }
    }
}
