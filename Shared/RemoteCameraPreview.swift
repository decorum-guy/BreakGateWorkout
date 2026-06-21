import Foundation
import SwiftUI

#if os(macOS)
import AppKit

struct RemoteCameraPreview: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> RemoteCameraPreviewView {
        let view = RemoteCameraPreviewView()
        view.setImage(image)
        return view
    }

    func updateNSView(_ nsView: RemoteCameraPreviewView, context: Context) {
        nsView.setImage(image)
    }
}

final class RemoteCameraPreviewView: NSView {
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setImage(_ image: NSImage?) {
        imageView.image = image
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
#else
import UIKit

struct RemoteCameraPreview: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}
#endif
