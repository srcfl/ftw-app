import SwiftUI
import UIKit

/// Keeps a pinch on a chart for the chart.
///
/// A view that zooms in from its source (`navigationTransition(.zoom)`)
/// can be pinched closed by the system, and on a chart that pinch closed
/// the whole view instead of zooming time (Fredrik, 26 October 2026). While
/// a finger is on the chart this turns the transition's gesture off, and
/// on again when the last finger lifts. On iOS 26 that gesture is a private
/// transform recognizer on the navigation stack's hosting view, the same
/// view SwiftUI hangs this recognizer on (seen in the simulator), and it
/// cannot be made to wait for another, so it is switched off instead. The
/// back swipe from the edge, on the navigation controller's own view, and
/// a pinch outside the chart keep their way.
///
/// The one UIKit piece outside the camera: SwiftUI has no say over the
/// transition's own gesture.
struct ChartPinchGuard: UIGestureRecognizerRepresentable {
    /// A finger is on the chart, as the chart's own gesture knows it.
    var touching: Bool

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        // Only watches: it sees each touch land and never takes one.
        let watch = UIPinchGestureRecognizer()
        watch.cancelsTouchesInView = false
        watch.delaysTouchesBegan = false
        watch.delaysTouchesEnded = false
        watch.delegate = context.coordinator
        return watch
    }

    func updateUIGestureRecognizer(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        if !touching { context.coordinator.release() }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The transition gestures this switched off, to switch on again.
        private var held: [WeakRecognizer] = []

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            hold(above: g.view)
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Switch off every transition gesture on this view and those above.
        private func hold(above view: UIView?) {
            var v = view
            while let here = v {
                for r in here.gestureRecognizers ?? [] where Self.closesTheView(r) && r.isEnabled {
                    r.isEnabled = false
                    held.append(WeakRecognizer(r))
                }
                v = here.superview
            }
        }

        func release() {
            for h in held { h.recognizer?.isEnabled = true }
            held.removeAll()
        }

        /// The zoom transition's pinch to close: a pinch, or iOS 26's
        /// private transform recognizer.
        static func closesTheView(_ r: UIGestureRecognizer) -> Bool {
            r is UIPinchGestureRecognizer || String(describing: type(of: r)).contains("TransformGesture")
        }
    }

    @MainActor struct WeakRecognizer {
        weak var recognizer: UIGestureRecognizer?
        init(_ r: UIGestureRecognizer) { recognizer = r }
    }
}
