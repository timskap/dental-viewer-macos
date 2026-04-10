import Foundation
import CoreGraphics
import ImageIO
import simd

struct DICOMSlice {
    var rows: Int = 0                     // image height
    var cols: Int = 0                     // image width
    var bitsAllocated: Int = 8
    var pixelRepresentation: Int = 0      // 0=unsigned 1=signed
    var pixelSpacing: SIMD2<Float> = SIMD2(0, 0)
    var sliceThickness: Float = 0
    var instanceNumber: Int = 0
    var imagePositionZ: Float = 0
    var rescaleSlope: Float = 1
    var rescaleIntercept: Float = 0
    var transferSyntaxUID: String = ""
    var pixels8: Data = Data()            // decoded 8-bit grayscale, rows*cols bytes
}

enum DICOMError: Error, LocalizedError {
    case notDICOM
    case unsupportedTransferSyntax(String)
    case decodeFailed
    case truncated
    case noFilesFound

    var errorDescription: String? {
        switch self {
        case .notDICOM: return "File is not a valid DICOM"
        case .unsupportedTransferSyntax(let s): return "Unsupported DICOM transfer syntax: \(s)"
        case .decodeFailed: return "Failed to decode DICOM pixel data"
        case .truncated: return "DICOM file is truncated"
        case .noFilesFound: return "No DICOM files found in the selected folder"
        }
    }
}

/// Pure-Swift DICOM parser supporting:
/// - 128-byte preamble + DICM magic
/// - File Meta Information group (always Explicit VR LE)
/// - Explicit VR Little Endian dataset
/// - Implicit VR Little Endian dataset
/// - Encapsulated PixelData with JPEG Baseline / JPEG variants (decoded via ImageIO)
/// - Uncompressed PixelData (8-bit and 16-bit, 16-bit is rescaled to 8-bit per slice)
enum DICOMParser {

    static func parse(url: URL) throws -> DICOMSlice {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> DICOMSlice {
        guard data.count > 132 else { throw DICOMError.truncated }
        guard data.subdata(in: 128..<132) == Data("DICM".utf8) else {
            throw DICOMError.notDICOM
        }

        var slice = DICOMSlice()
        var offset = 132

        // ----- File Meta Information (always Explicit VR LE) -----
        // First element MUST be (0002,0000) UL Group Length
        let metaEnd: Int
        do {
            let e = try readExplicit(data, offset)
            guard e.group == 0x0002, e.elem == 0x0000, e.vr == "UL", e.length == 4 else {
                throw DICOMError.notDICOM
            }
            let groupLen = Int(data.u32le(e.valueOffset))
            metaEnd = e.next + groupLen
            offset = e.next
        }

        while offset < metaEnd {
            let e = try readExplicit(data, offset)
            if e.group == 0x0002 && e.elem == 0x0010 {
                slice.transferSyntaxUID = readASCII(data, e.valueOffset, e.length)
            }
            offset = e.next
        }

        // ----- Decide encoding for the dataset -----
        let tsUID = slice.transferSyntaxUID.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        let isExplicit: Bool
        let isEncapsulated: Bool
        switch tsUID {
        case "1.2.840.10008.1.2":
            isExplicit = false; isEncapsulated = false                  // Implicit VR LE
        case "1.2.840.10008.1.2.1":
            isExplicit = true;  isEncapsulated = false                  // Explicit VR LE
        case "1.2.840.10008.1.2.4.50",                                  // JPEG Baseline (Process 1)
             "1.2.840.10008.1.2.4.51",                                  // JPEG Extended (Process 2 & 4)
             "1.2.840.10008.1.2.4.57",                                  // JPEG Lossless, Non-Hierarchical
             "1.2.840.10008.1.2.4.70",                                  // JPEG Lossless, First-Order Prediction
             "1.2.840.10008.1.2.4.80",                                  // JPEG-LS Lossless
             "1.2.840.10008.1.2.4.81",                                  // JPEG-LS Lossy
             "1.2.840.10008.1.2.4.90",                                  // JPEG 2000 Lossless
             "1.2.840.10008.1.2.4.91":                                  // JPEG 2000
            isExplicit = true;  isEncapsulated = true
        default:
            // Best-effort: assume explicit-VR LE uncompressed
            isExplicit = true;  isEncapsulated = false
        }

        // ----- Walk dataset -----
        while offset + 8 <= data.count {
            let e: Element
            do {
                e = isExplicit ? try readExplicit(data, offset)
                               : try readImplicit(data, offset)
            } catch { break }

            let tag = (UInt32(e.group) << 16) | UInt32(e.elem)
            switch tag {
            case 0x00280010: slice.rows = Int(data.u16le(e.valueOffset))
            case 0x00280011: slice.cols = Int(data.u16le(e.valueOffset))
            case 0x00280100: slice.bitsAllocated = Int(data.u16le(e.valueOffset))
            case 0x00280103: slice.pixelRepresentation = Int(data.u16le(e.valueOffset))
            case 0x00280030:
                let parts = readASCII(data, e.valueOffset, e.length)
                    .split(separator: "\\").compactMap { Float($0) }
                if parts.count >= 2 { slice.pixelSpacing = SIMD2(parts[0], parts[1]) }
            case 0x00180050:
                if let v = Float(readASCII(data, e.valueOffset, e.length)) {
                    slice.sliceThickness = v
                }
            case 0x00200013:
                if let v = Int(readASCII(data, e.valueOffset, e.length)) {
                    slice.instanceNumber = v
                }
            case 0x00200032:
                let parts = readASCII(data, e.valueOffset, e.length)
                    .split(separator: "\\").compactMap { Float($0) }
                if parts.count >= 3 { slice.imagePositionZ = parts[2] }
            case 0x00281052:
                if let v = Float(readASCII(data, e.valueOffset, e.length)) {
                    slice.rescaleIntercept = v
                }
            case 0x00281053:
                if let v = Float(readASCII(data, e.valueOffset, e.length)) {
                    slice.rescaleSlope = v
                }
            case 0x7FE00010:
                if isEncapsulated {
                    slice.pixels8 = try decodeEncapsulatedPixelData(data, startOffset: e.valueOffset)
                } else {
                    let raw = data.subdata(in: e.valueOffset..<min(e.valueOffset + e.length, data.count))
                    if slice.bitsAllocated == 16 {
                        slice.pixels8 = downsample16to8(raw, signed: slice.pixelRepresentation == 1)
                    } else {
                        slice.pixels8 = raw
                    }
                }
                return slice
            default:
                break
            }
            offset = e.next
        }

        return slice
    }

    // MARK: - Element parsing

    private struct Element {
        let group: UInt16
        let elem: UInt16
        let vr: String
        let length: Int
        let valueOffset: Int
        let next: Int
    }

    private static func readExplicit(_ d: Data, _ o: Int) throws -> Element {
        guard o + 8 <= d.count else { throw DICOMError.truncated }
        let group = d.u16le(o)
        let elem  = d.u16le(o + 2)
        let vr = String(data: d.subdata(in: (o + 4)..<(o + 6)), encoding: .ascii) ?? ""
        var off = o + 6
        let length: Int
        if ["OB","OW","OF","OD","SQ","UT","UN"].contains(vr) {
            off += 2 // reserved
            guard off + 4 <= d.count else { throw DICOMError.truncated }
            length = Int(d.u32le(off))
            off += 4
        } else {
            guard off + 2 <= d.count else { throw DICOMError.truncated }
            length = Int(d.u16le(off))
            off += 2
        }
        let valueOffset = off
        let next: Int
        if length == 0xFFFFFFFF {
            // Undefined length — caller handles items (only for PixelData here)
            next = valueOffset
        } else {
            next = valueOffset + length
        }
        return Element(group: group, elem: elem, vr: vr,
                       length: length, valueOffset: valueOffset, next: next)
    }

    private static func readImplicit(_ d: Data, _ o: Int) throws -> Element {
        guard o + 8 <= d.count else { throw DICOMError.truncated }
        let group = d.u16le(o)
        let elem  = d.u16le(o + 2)
        let length = Int(d.u32le(o + 4))
        let valueOffset = o + 8
        let next = length == 0xFFFFFFFF ? valueOffset : valueOffset + length
        return Element(group: group, elem: elem, vr: "  ",
                       length: length, valueOffset: valueOffset, next: next)
    }

    private static func readASCII(_ d: Data, _ off: Int, _ len: Int) -> String {
        let end = min(off + len, d.count)
        guard end > off else { return "" }
        let sub = d.subdata(in: off..<end)
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        return String(data: sub, encoding: .ascii)?
            .trimmingCharacters(in: trim) ?? ""
    }

    // MARK: - Encapsulated PixelData (JPEG fragments)

    private static func decodeEncapsulatedPixelData(_ d: Data, startOffset: Int) throws -> Data {
        var p = startOffset

        // Item: Basic Offset Table (FFFE,E000) — may be empty.
        guard p + 8 <= d.count,
              d.u16le(p) == 0xFFFE, d.u16le(p + 2) == 0xE000 else {
            throw DICOMError.decodeFailed
        }
        let botLen = Int(d.u32le(p + 4))
        p += 8 + botLen

        // Concatenate all subsequent fragment items into one JPEG bitstream
        // until we hit the Sequence Delimiter (FFFE,E0DD).
        var jpeg = Data()
        while p + 8 <= d.count {
            let g = d.u16le(p)
            let e = d.u16le(p + 2)
            let len = Int(d.u32le(p + 4))
            p += 8
            if g == 0xFFFE && e == 0xE0DD { break }              // sequence end
            if g == 0xFFFE && e == 0xE000 {
                let end = min(p + len, d.count)
                jpeg.append(d.subdata(in: p..<end))
                p += len
            } else {
                break
            }
        }

        guard !jpeg.isEmpty,
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw DICOMError.decodeFailed
        }

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
            throw DICOMError.decodeFailed
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Data(bytes)
    }

    // MARK: - 16-bit downsampling for uncompressed CT

    private static func downsample16to8(_ data: Data, signed: Bool) -> Data {
        let count = data.count / 2
        guard count > 0 else { return Data() }

        // First pass: find min/max so we can map the actual range to 0..255
        var minV: Int32 = .max
        var maxV: Int32 = .min
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<count {
                let v: Int32 = signed ? Int32(Int16(bitPattern: p[i])) : Int32(p[i])
                if v < minV { minV = v }
                if v > maxV { maxV = v }
            }
        }
        let range = max(maxV - minV, 1)
        var out = [UInt8](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<count {
                let v: Int32 = signed ? Int32(Int16(bitPattern: p[i])) : Int32(p[i])
                let n = (v - minV) * 255 / range
                out[i] = UInt8(max(0, min(255, n)))
            }
        }
        return Data(out)
    }
}

// MARK: - Little-endian byte readers

private extension Data {
    func u16le(_ offset: Int) -> UInt16 {
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }
    func u32le(_ offset: Int) -> UInt32 {
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
