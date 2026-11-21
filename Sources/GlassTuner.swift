import AppKit
import QuartzCore

/// Clearer Liquid Glass: SwiftUI's glass is a private `glassBackground` backdrop filter whose blur and milky face
/// aren't exposed, so we thin them on the rendered layer. A harmless no-op if the layer structure changes.
enum GlassTuner {
    static func clarify(_ root: CALayer, blur: CGFloat = 2, face: CGFloat = 0.25) {
        func walk(_ l: CALayer) {
            for (key, filters) in [("filters", l.filters), ("backgroundFilters", l.backgroundFilters)] {
                for case let f as NSObject in filters ?? [] where f.description.contains("glassBackground") {
                    guard let name = f.value(forKey: "name") as? String,
                          let radius = (f.value(forKey: "inputBlurRadius") as? NSNumber)?.doubleValue, radius > blur else { continue }
                    l.setValue(blur, forKeyPath: "\(key).\(name).inputBlurRadius")
                    l.setValue(face, forKeyPath: "\(key).\(name).inputFaceOpacity")
                }
            }
            l.sublayers?.forEach(walk)
        }
        walk(root)
    }
}
