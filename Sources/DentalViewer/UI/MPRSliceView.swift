import SwiftUI
import CoreGraphics

enum MPRPlane: String {
    case axial = "Axial"
    case coronal = "Coronal"
    case sagittal = "Sagittal"
}

struct MPRSliceView: View {
    let plane: MPRPlane
    @EnvironmentObject var store: VolumeStore
    @State private var sliceFraction: Float = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plane.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let v = store.volume {
                    Text("\(currentIndex(for: v)) / \(maxIndex(for: v))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                Color.black
                if let v = store.volume,
                   let img = MPRRenderer.makeImage(
                       volume: v,
                       plane: plane,
                       fraction: sliceFraction,
                       windowCenter: store.windowCenter,
                       windowWidth: store.windowWidth
                   ) {
                    // IMPORTANT: use the *physical* aspect ratio, not the
                    // pixel aspect — anisotropic voxels (0.3×0.3×0.5 mm etc.)
                    // would otherwise render visibly squished.
                    Image(decorative: img, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(physicalAspect(for: v), contentMode: .fit)
                } else {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.volume != nil {
                    OrientationLabels(plane: plane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Slider(value: $sliceFraction, in: 0...1)
                .controlSize(.small)
                .disabled(store.volume == nil)
        }
        .padding(8)
    }

    private func maxIndex(for v: Volume) -> Int {
        switch plane {
        case .axial: return max(v.depth - 1, 0)
        case .coronal: return max(v.height - 1, 0)
        case .sagittal: return max(v.width - 1, 0)
        }
    }

    private func currentIndex(for v: Volume) -> Int {
        let m = maxIndex(for: v)
        return min(m, max(0, Int(sliceFraction * Float(m))))
    }

    /// Physical width / physical height of the slice in mm.
    /// This is what `.aspectRatio` should respect — NOT the voxel grid aspect.
    private func physicalAspect(for v: Volume) -> CGFloat {
        let pw: Float
        let ph: Float
        switch plane {
        case .axial:
            pw = Float(v.width)  * v.spacing.x
            ph = Float(v.height) * v.spacing.y
        case .coronal:
            pw = Float(v.width)  * v.spacing.x
            ph = Float(v.depth)  * v.spacing.z
        case .sagittal:
            pw = Float(v.height) * v.spacing.y
            ph = Float(v.depth)  * v.spacing.z
        }
        return CGFloat(pw / max(ph, 0.0001))
    }
}

// MARK: - Orientation labels (radiology convention)

/// Small A/P/R/L/S/I markers overlaid on each MPR view so the orientation
/// is unambiguous. Standard radiology convention:
/// - Axial:    A top, P bottom, R left,  L right  (looking up from feet)
/// - Coronal:  S top, I bottom, R left,  L right  (looking from front)
/// - Sagittal: S top, I bottom, A left,  P right  (looking from patient's left)
private struct OrientationLabels: View {
    let plane: MPRPlane

    var body: some View {
        let labels = labels(for: plane)
        ZStack {
            VStack {
                Text(labels.top).labelStyle()
                Spacer()
                Text(labels.bottom).labelStyle()
            }
            HStack {
                Text(labels.left).labelStyle()
                Spacer()
                Text(labels.right).labelStyle()
            }
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    private func labels(for plane: MPRPlane) -> (top: String, bottom: String, left: String, right: String) {
        switch plane {
        case .axial:    return ("A", "P", "R", "L")
        case .coronal:  return ("S", "I", "R", "L")
        case .sagittal: return ("S", "I", "A", "P")
        }
    }
}

private extension Text {
    func labelStyle() -> some View {
        self.font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(Color.yellow.opacity(0.85))
            .shadow(color: .black, radius: 1.5)
    }
}

// MARK: - Slice extraction

enum MPRRenderer {

    static func makeImage(volume: Volume,
                          plane: MPRPlane,
                          fraction: Float,
                          windowCenter: Float,
                          windowWidth: Float) -> CGImage? {
        let w: Int
        let h: Int
        switch plane {
        case .axial:    w = volume.width;  h = volume.height
        case .coronal:  w = volume.width;  h = volume.depth
        case .sagittal: w = volume.height; h = volume.depth
        }
        guard w > 0, h > 0 else { return nil }

        let width = volume.width
        let height = volume.height
        let depth = volume.depth
        let sliceStride = width * height

        // Map [0..1] window into 8-bit space
        let lo = Double(max(0.0, windowCenter - windowWidth * 0.5)) * 255.0
        let hi = Double(min(1.0, windowCenter + windowWidth * 0.5)) * 255.0
        let span = max(hi - lo, 1.0)

        var bytes = [UInt8](repeating: 0, count: w * h)

        volume.voxels.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }

            switch plane {
            case .axial:
                // Axial slice (XY plane): looking up from the patient's feet.
                // DICOM row 0 = anterior, col 0 = patient's right by convention,
                // which maps directly to viewer-top = anterior, viewer-left =
                // patient-right (standard radiology orientation). No flip.
                let z = clamp(Int(fraction * Float(depth - 1)), 0, depth - 1)
                let base = z * sliceStride
                for y in 0..<height {
                    let srcRow = base + y * width
                    let dstRow = y * width
                    for x in 0..<width {
                        bytes[dstRow + x] = window(p[srcRow + x], lo: lo, span: span)
                    }
                }

            case .coronal:
                let y = clamp(Int(fraction * Float(height - 1)), 0, height - 1)
                for z in 0..<depth {
                    for x in 0..<width {
                        let v = p[z * sliceStride + y * width + x]
                        bytes[(depth - 1 - z) * w + x] = window(v, lo: lo, span: span)
                    }
                }

            case .sagittal:
                let x = clamp(Int(fraction * Float(width - 1)), 0, width - 1)
                for z in 0..<depth {
                    for y in 0..<height {
                        let v = p[z * sliceStride + y * width + x]
                        bytes[(depth - 1 - z) * w + y] = window(v, lo: lo, span: span)
                    }
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    @inline(__always)
    private static func window(_ v: UInt8, lo: Double, span: Double) -> UInt8 {
        let n = (Double(v) - lo) * 255.0 / span
        if n <= 0 { return 0 }
        if n >= 255 { return 255 }
        return UInt8(n)
    }

    @inline(__always)
    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        v < lo ? lo : (v > hi ? hi : v)
    }
}
