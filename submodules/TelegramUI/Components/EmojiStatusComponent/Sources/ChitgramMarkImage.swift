import Foundation
import UIKit
import Display
import AppBundle

private var chitgramMarkImages: [CGFloat: UIImage] = [:]

/// The Chitgram logo tile at a status size, with its rounded corners (Android `ChitgramBadgeDrawable` at rest). Main
/// thread, cached by size.
func chitgramMarkImage(size: CGSize) -> UIImage? {
    let side = floor(min(size.width, size.height) * 0.94)
    if side <= 0.0 {
        return nil
    }
    if let image = chitgramMarkImages[side] {
        return image
    }
    guard let tile = UIImage(bundleImageName: "Chitgram/BadgeTile") else {
        return nil
    }
    let image = generateImage(CGSize(width: side, height: side), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        UIGraphicsPushContext(context)
        UIBezierPath(roundedRect: bounds, cornerRadius: size.width * 0.225).addClip()
        tile.draw(in: bounds)
        UIGraphicsPopContext()
    })
    chitgramMarkImages[side] = image
    return image
}
