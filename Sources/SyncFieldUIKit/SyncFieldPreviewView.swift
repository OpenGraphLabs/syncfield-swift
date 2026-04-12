#if canImport(UIKit) && canImport(AVFoundation) && os(iOS)
import UIKit
import AVFoundation
import SyncField

public final class SyncFieldPreviewView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    public init(stream: iPhoneCameraStream) {
        super.init(frame: .zero)
        previewLayer.session = stream.captureSession
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
