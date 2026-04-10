import Foundation
import CoreGraphics
import ImageIO

// Tiny CLI escape hatch — useful for smoke-testing the DICOM path without
// launching the UI. Without flags this falls through to the SwiftUI app.

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--parse" {
    do {
        let s = try DICOMParser.parse(url: URL(fileURLWithPath: args[2]))
        print("""
        OK
          rows=\(s.rows) cols=\(s.cols)
          bitsAllocated=\(s.bitsAllocated)  pixelRep=\(s.pixelRepresentation)
          instanceNumber=\(s.instanceNumber)  imagePositionZ=\(s.imagePositionZ)
          transferSyntax=\(s.transferSyntaxUID)
          pixelSpacing=\(s.pixelSpacing.x)×\(s.pixelSpacing.y)  sliceThickness=\(s.sliceThickness)
          decoded pixels8 bytes=\(s.pixels8.count) (expected \(s.rows * s.cols))
        """)
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

if args.count >= 3 && args[1] == "--load" {
    do {
        let v = try DICOMSeriesLoader.load(folder: URL(fileURLWithPath: args[2])) {
            print("[loader] \($0)")
        }
        print("VOLUME \(v.width)×\(v.height)×\(v.depth)  spacing=\(v.spacing.x)×\(v.spacing.y)×\(v.spacing.z) mm  bytes=\(v.voxels.count)")
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

if args.count >= 4 && args[1] == "--dump-file" {
    // --dump-file <input.dcm> <output.pgm>
    // Parses ONE DICOM file and writes its decoded pixels to a PGM.
    // Tests the parser + JPEG decode path in isolation (no loader/MPR).
    do {
        let s = try DICOMParser.parse(url: URL(fileURLWithPath: args[2]))
        let w = s.cols
        let h = s.rows
        var out = Data("P5\n\(w) \(h)\n255\n".utf8)
        out.append(s.pixels8)
        try out.write(to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3])  \(w)×\(h)  bytes=\(s.pixels8.count)  ts=\(s.transferSyntaxUID)")
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

if args.count >= 6 && args[1] == "--export-slice" {
    // --export-slice <folder> <axial|coronal|sagittal> <index> <output.pgm>
    do {
        let v = try DICOMSeriesLoader.load(folder: URL(fileURLWithPath: args[2])) { _ in }

        let plane: MPRPlane
        switch args[3].lowercased() {
        case "axial":    plane = .axial
        case "coronal":  plane = .coronal
        case "sagittal": plane = .sagittal
        default:
            print("ERROR: unknown plane \(args[3])")
            exit(1)
        }
        let index = Int(args[4]) ?? 0
        let maxIdx: Int
        switch plane {
        case .axial:    maxIdx = max(v.depth - 1, 1)
        case .coronal:  maxIdx = max(v.height - 1, 1)
        case .sagittal: maxIdx = max(v.width - 1, 1)
        }
        let fraction = Float(index) / Float(maxIdx)

        guard let img = MPRRenderer.makeImage(
            volume: v,
            plane: plane,
            fraction: fraction,
            windowCenter: 0.5,
            windowWidth: 1.0
        ) else {
            print("ERROR: slice render failed")
            exit(1)
        }

        // Pull raw 8-bit bytes back out of the CGImage
        let w = img.width
        let h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            print("ERROR: could not create output context")
            exit(1)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = Data("P5\n\(w) \(h)\n255\n".utf8)
        out.append(bytes, count: bytes.count)
        try out.write(to: URL(fileURLWithPath: args[5]))
        print("wrote \(args[5])  \(w)×\(h)  plane=\(args[3])  index=\(index)/\(maxIdx)")
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}

DentalViewerApp.main()
