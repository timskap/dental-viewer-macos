import SwiftUI
import MetalKit
import simd

// MARK: - Uniform layout shared with the Metal shader

/// Mirrors the `Uniforms` struct in ShaderSource.metal exactly.
/// All members are 16-byte aligned (float4 / float4x4) so this struct
/// is binary-compatible with Metal's automatic layout.
struct VolumeUniforms {
    var invViewProj: simd_float4x4 = matrix_identity_float4x4
    var cameraPos: SIMD4<Float> = .zero
    var windowAndMode: SIMD4<Float> = .zero
    var volumeSize: SIMD4<Float> = .zero
    var clipParams: SIMD4<Float> = .zero
}

// MARK: - NSView subclass that forwards scroll-wheel events for zoom

final class ZoomableMTKView: MTKView {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - SwiftUI wrapper

struct VolumeMetalView: NSViewRepresentable {
    @EnvironmentObject var store: VolumeStore
    @Binding var yaw: Float
    @Binding var pitch: Float
    @Binding var distance: Float

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomableMTKView {
        let view = ZoomableMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.onScroll = { [weak view] dy in
            guard let view else { return }
            // Read parent through coordinator (it always has the latest binding)
            (view.delegate as? Coordinator)?.handleScroll(dy)
        }
        context.coordinator.setup(view: view)
        context.coordinator.parent = self
        return view
    }

    func updateNSView(_ view: ZoomableMTKView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.uploadVolumeIfNeeded(store.volume)
    }

    // MARK: - Coordinator (Metal renderer)

    final class Coordinator: NSObject, MTKViewDelegate {
        var parent: VolumeMetalView?
        var device: MTLDevice!
        var queue: MTLCommandQueue!
        var pipeline: MTLRenderPipelineState?
        var volumeTexture: MTLTexture?
        private var lastVolumeKey: Int = 0
        private var aspect: Float = 1

        func setup(view: MTKView) {
            guard let dev = view.device else { return }
            device = dev
            queue = dev.makeCommandQueue()
            view.delegate = self

            do {
                let lib = try dev.makeLibrary(source: ShaderSource.metal, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: "vs_quad")
                desc.fragmentFunction = lib.makeFunction(name: "fs_volume")
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipeline = try dev.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("VolumeMetalView pipeline error: \(error)")
            }
        }

        func handleScroll(_ dy: CGFloat) {
            guard let parent else { return }
            let newDist = parent.distance - Float(dy) * 0.02
            parent.distance = max(0.6, min(8.0, newDist))
        }

        func uploadVolumeIfNeeded(_ volume: Volume?) {
            guard let volume else { volumeTexture = nil; return }
            // Cheap key — collisions don't matter beyond cache invalidation.
            let key = volume.width &* 73856093 ^ volume.height &* 19349663 ^ volume.depth &* 83492791 ^ volume.voxels.count
            if key == lastVolumeKey && volumeTexture != nil { return }
            lastVolumeKey = key

            let desc = MTLTextureDescriptor()
            desc.textureType = .type3D
            desc.pixelFormat = .r8Unorm
            desc.width  = volume.width
            desc.height = volume.height
            desc.depth  = volume.depth
            desc.usage = [.shaderRead]
            desc.storageMode = .shared

            guard let tex = device.makeTexture(descriptor: desc) else { return }
            let bytesPerRow   = volume.width
            let bytesPerImage = volume.width * volume.height
            volume.voxels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    tex.replace(
                        region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: base,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage
                    )
                }
            }
            volumeTexture = tex
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            aspect = size.height > 0 ? Float(size.width / size.height) : 1
        }

        func draw(in view: MTKView) {
            guard let parent,
                  let pipeline,
                  let tex = volumeTexture,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
            else { return }

            let store = parent.store
            let yaw    = parent.yaw
            let pitch  = parent.pitch
            let dist   = parent.distance

            let cameraPos = SIMD3<Float>(
                dist * cos(pitch) * sin(yaw),
                dist * sin(pitch),
                dist * cos(pitch) * cos(yaw)
            )
            let viewM = lookAtRH(eye: cameraPos, center: .zero, up: SIMD3(0, 1, 0))
            let projM = perspectiveRH(fovYRadians: .pi / 4, aspect: aspect, near: 0.05, far: 50)
            let invVP = (projM * viewM).inverse

            // Normalize the volume so its longest physical dimension fits a 1-unit box.
            let phys = store.volume?.physicalSizeMM ?? SIMD3(1, 1, 1)
            let maxDim = max(max(phys.x, phys.y), phys.z)
            let volSize = phys / maxDim

            var u = VolumeUniforms()
            u.invViewProj  = invVP
            u.cameraPos    = SIMD4(cameraPos, 0)
            u.windowAndMode = SIMD4(store.windowCenter, store.windowWidth, Float(store.renderMode.rawValue), 0)
            u.volumeSize   = SIMD4(volSize, 0)
            u.clipParams   = SIMD4(
                store.clipEnabled ? 1 : 0,
                Float(store.clipAxis),
                store.clipPosition,
                store.clipFlip ? 1 : 0
            )

            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}

// MARK: - Math helpers (right-handed)

func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4( s.x,  u.x, -f.x, 0)
    m.columns.1 = SIMD4( s.y,  u.y, -f.y, 0)
    m.columns.2 = SIMD4( s.z,  u.z, -f.z, 0)
    m.columns.3 = SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    return m
}

func perspectiveRH(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1 / tan(fovYRadians / 2)
    var m = simd_float4x4()
    m.columns.0 = SIMD4(f / aspect, 0,                              0,  0)
    m.columns.1 = SIMD4(0,          f,                              0,  0)
    m.columns.2 = SIMD4(0,          0,        far / (near - far),      -1)
    m.columns.3 = SIMD4(0,          0,  (far * near) / (near - far),    0)
    return m
}
