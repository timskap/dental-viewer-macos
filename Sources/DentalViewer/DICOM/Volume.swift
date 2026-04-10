import Foundation
import simd

/// A 3D voxel grid loaded from a DICOM series.
/// Voxels are stored row-major: index = z*width*height + y*width + x.
struct Volume {
    let width: Int
    let height: Int
    let depth: Int
    let spacing: SIMD3<Float>   // mm per voxel
    let voxels: Data            // width*height*depth bytes (8-bit grayscale)

    /// Physical size of the volume in mm.
    var physicalSizeMM: SIMD3<Float> {
        SIMD3(Float(width), Float(height), Float(depth)) * spacing
    }
}
