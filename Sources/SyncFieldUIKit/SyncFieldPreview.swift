#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI
import UIKit
import SyncField

public struct SyncFieldPreview: UIViewRepresentable {
    private let stream: iPhoneCameraStream
    public init(stream: iPhoneCameraStream) { self.stream = stream }
    public func makeUIView(context: Context) -> SyncFieldPreviewView {
        SyncFieldPreviewView(stream: stream)
    }
    public func updateUIView(_ uiView: SyncFieldPreviewView, context: Context) {}
}
#endif
