import AVFoundation
import SwiftUI

/// Reads a pairing QR, or an assistant's consent QR, through the camera.
/// The first code that looks like an FTW link is handed over once; the
/// camera stops at that moment.
struct QRScanner: View {
    var onCode: (String) -> Void
    @State private var allowed: Bool?

    static func looksLikePairing(_ text: String) -> Bool {
        text.contains("ftw.energy") || text.contains("/p#")
    }

    var body: some View {
        Group {
            switch allowed {
            case .some(true):
                CameraView(onCode: onCode)
            case .some(false):
                Text("FTW needs the camera to read the pairing code. Allow it in Settings, then try again.")
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
                    .padding()
            case .none:
                Color.black
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
        }
    }
}

/// The capture session, started and stopped off the main thread as
/// AVFoundation asks. Held in a box so the closures that move it are honest
/// about crossing threads.
private final class CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "energy.ftw.camera")

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }
}

private struct CameraView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.capture.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject {
        let capture = CaptureBox()
        var onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func attach(_ view: PreviewView) {
            let session = capture.session
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            view.preview.session = session
            view.preview.videoGravity = .resizeAspectFill
            capture.start()
        }

        func found(_ text: String) {
            guard !done, QRScanner.looksLikePairing(text) else { return }
            done = true
            capture.stop()
            onCode(text)
        }
    }
}

extension CameraView.Coordinator: @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let text = (object as? AVMetadataMachineReadableCodeObject)?.stringValue { found(text) }
        }
    }
}
