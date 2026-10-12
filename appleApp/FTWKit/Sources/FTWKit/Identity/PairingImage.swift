import CoreImage
import Foundation

/// A pairing link read off a picture of the QR. The simulator has no camera,
/// so this is how pairing is tried there. The link then takes the same path
/// as one the camera read.
public enum PairingImage {
    /// The first QR in the picture that `Enrollment` accepts, or nil.
    public static func link(in imageData: Data) -> String? {
        guard let image = CIImage(data: imageData),
              let detector = CIDetector(
                  ofType: CIDetectorTypeQRCode,
                  context: CIContext(options: [.useSoftwareRenderer: true]),
                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else { return nil }
        return detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first { (try? Enrollment.parse(scanned: $0)) != nil }
    }
}
