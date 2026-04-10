import Foundation
import simd

enum DICOMSeriesLoader {

    /// Recursively scan a folder for DICOM files, parse them, and stack the
    /// slices into a single Volume. Reports progress strings on the calling
    /// queue via `progress`.
    static func load(folder: URL, progress: @escaping (String) -> Void) throws -> Volume {
        let fm = FileManager.default

        // Collect candidate files (.dcm or extensionless I*.dcm-style names).
        var files: [URL] = []
        if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                      isFile else { continue }
                let ext = url.pathExtension.lowercased()
                if ext == "dcm" || ext == "dicom" || ext.isEmpty {
                    files.append(url)
                }
            }
        }
        guard !files.isEmpty else { throw DICOMError.noFilesFound }

        progress("Found \(files.count) candidate files")

        // Parse — silently skip non-DICOM files (e.g. DICOMDIR or .ini files).
        var parsed: [(slice: DICOMSlice, name: String)] = []
        parsed.reserveCapacity(files.count)
        for (i, url) in files.enumerated() {
            do {
                let s = try DICOMParser.parse(url: url)
                if s.rows > 0 && s.cols > 0 && !s.pixels8.isEmpty {
                    parsed.append((s, url.lastPathComponent))
                }
            } catch {
                // ignore non-DICOM siblings
            }
            if i % 25 == 0 {
                progress("Loading slice \(i + 1)/\(files.count)…")
            }
        }
        guard !parsed.isEmpty else { throw DICOMError.noFilesFound }

        // A single DICOM folder often contains multiple sub-series mixed
        // together — e.g. a 256×256 JPEG localizer alongside 390×390
        // uncompressed CBCT slices. Group by (rows, cols, bitsAllocated) and
        // keep only the dominant group so we don't try to stack slices of
        // different dimensions into one volume.
        struct GroupKey: Hashable { let rows: Int; let cols: Int; let bits: Int }
        var groups: [GroupKey: [(slice: DICOMSlice, name: String)]] = [:]
        for entry in parsed {
            let key = GroupKey(
                rows: entry.slice.rows,
                cols: entry.slice.cols,
                bits: entry.slice.bitsAllocated
            )
            groups[key, default: []].append(entry)
        }
        guard let dominant = groups.max(by: { $0.value.count < $1.value.count })?.value else {
            throw DICOMError.noFilesFound
        }
        if dominant.count != parsed.count {
            progress("Using dominant sub-series: \(dominant.count) / \(parsed.count) slices (others have different dimensions)")
        }

        // Sort by InstanceNumber → Z position → filename (numeric-aware fallback).
        var slices = dominant
        slices.sort { a, b in
            if a.slice.instanceNumber != b.slice.instanceNumber {
                return a.slice.instanceNumber < b.slice.instanceNumber
            }
            if a.slice.imagePositionZ != b.slice.imagePositionZ {
                return a.slice.imagePositionZ < b.slice.imagePositionZ
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        let first = slices[0].slice
        let w = first.cols
        let h = first.rows
        let d = slices.count
        progress("Building volume \(w)×\(h)×\(d)…")

        let sliceBytes = w * h
        var voxels = Data(count: sliceBytes * d)
        voxels.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            for (i, entry) in slices.enumerated() {
                let bytes = min(entry.slice.pixels8.count, sliceBytes)
                entry.slice.pixels8.withUnsafeBytes { srcRaw in
                    if let src = srcRaw.bindMemory(to: UInt8.self).baseAddress {
                        memcpy(dst.advanced(by: i * sliceBytes), src, bytes)
                    }
                }
            }
        }

        // Spacing — fall back to slice thickness when PixelSpacing is missing,
        // and to 0.2 mm (typical OP300 isotropic voxel) as a last resort.
        let fallback: Float = first.sliceThickness > 0 ? first.sliceThickness : 0.2
        let spacing = SIMD3<Float>(
            first.pixelSpacing.x > 0 ? first.pixelSpacing.x : fallback,
            first.pixelSpacing.y > 0 ? first.pixelSpacing.y : fallback,
            first.sliceThickness > 0 ? first.sliceThickness : fallback
        )

        return Volume(width: w, height: h, depth: d, spacing: spacing, voxels: voxels)
    }
}
