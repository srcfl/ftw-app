import AVFoundation
import SwiftUI
import Vision

/// Native camera QR scanner. Hands the first FTW pairing URL to the shared parser.
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var locked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ftw.qr"))
        session.addOutput(output)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if locked { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest { [weak self] req, _ in
            guard let code = (req.results as? [VNBarcodeObservation])?.first?.payloadStringValue else { return }
            guard code.contains("ftw.energy") || code.contains("/p#") else { return }
            DispatchQueue.main.async {
                guard let self, !self.locked else { return }
                self.locked = true
                self.session.stopRunning()
                self.onCode?(code)
            }
        }
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixel, options: [:]).perform([request])
    }
}
