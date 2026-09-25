import AVFoundation
import CoreImage
import SwiftUI

/// Reads a pairing QR through the camera. The first code that looks like an
/// FTW link is handed over once; the camera stops at that moment.
struct QRScanner: View {
    var onCode: (String) -> Void
    @State private var allowed: Bool?

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

/// QR codes in a still picture, for a Mac reading a screenshot of the code.
enum QRImage {
    static func looksLikePairing(_ text: String) -> Bool {
        text.contains("ftw.energy") || text.contains("/p#")
    }

    static func codes(in image: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func pairingCode(at url: URL) -> String? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        return codes(in: image).first(where: QRImage.looksLikePairing)
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

#if os(iOS)
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
            guard !done, QRImage.looksLikePairing(text) else { return }
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
#else
private struct CameraView: NSViewRepresentable {
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.capture.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    /// The Mac has no metadata output, so frames go through Core Image.
    @MainActor
    final class Coordinator: NSObject {
        let capture = CaptureBox()
        var onCode: (String) -> Void
        private var done = false
        private let frames = DispatchQueue(label: "energy.ftw.frames")
        private var reader: FrameReader?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func attach(_ view: NSView) {
            let session = capture.session
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            let reader = FrameReader(owner: self)
            self.reader = reader
            output.setSampleBufferDelegate(reader, queue: frames)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(preview)
            capture.start()
        }

        func found(_ text: String) {
            guard !done, QRImage.looksLikePairing(text) else { return }
            done = true
            capture.stop()
            onCode(text)
        }
    }

    /// Decodes on the frame queue and hands text to the main actor.
    final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private weak var owner: Coordinator?

        init(owner: Coordinator) {
            self.owner = owner
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            guard let text = QRImage.codes(in: CIImage(cvPixelBuffer: pixels)).first(where: QRImage.looksLikePairing) else { return }
            let target = owner
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target?.found(text) }
            }
        }
    }
}
#endif
