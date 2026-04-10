import Foundation

/// Inline Metal source for the volume raycaster.
/// Compiled at runtime via `device.makeLibrary(source:)` so the package
/// doesn't need to bundle a .metallib resource.
enum ShaderSource {
    static let metal: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vs_quad(uint vid [[vertex_id]]) {
        // Full-screen triangle strip (4 verts)
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        VertexOut o;
        o.position = float4(p[vid], 0, 1);
        o.uv = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);
        return o;
    }

    struct Uniforms {
        float4x4 invViewProj;
        float4 cameraPos;       // .xyz
        float4 windowAndMode;   // x=center, y=width, z=renderMode (0=MIP 1=composite)
        float4 volumeSize;      // .xyz, normalized so max dim = 1
        float4 clipParams;      // x=enabled, y=axis(0/1/2), z=position(0..1), w=flip
    };

    static inline bool intersectBox(float3 ro, float3 rd,
                                    float3 boxMin, float3 boxMax,
                                    thread float &t0, thread float &t1) {
        float3 inv = 1.0 / rd;
        float3 a = (boxMin - ro) * inv;
        float3 b = (boxMax - ro) * inv;
        float3 lo = min(a, b);
        float3 hi = max(a, b);
        t0 = max(max(lo.x, lo.y), lo.z);
        t1 = min(min(hi.x, hi.y), hi.z);
        return t1 > max(t0, 0.0);
    }

    fragment float4 fs_volume(VertexOut in [[stage_in]],
                              texture3d<float, access::sample> vol [[texture(0)]],
                              constant Uniforms& U [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        // Reconstruct world-space ray from clip-space coords.
        float2 ndc = float2(in.uv.x, 1.0 - in.uv.y) * 2.0 - 1.0;
        float4 nearH = U.invViewProj * float4(ndc, 0.0, 1.0);
        float4 farH  = U.invViewProj * float4(ndc, 1.0, 1.0);
        float3 nearP = nearH.xyz / nearH.w;
        float3 farP  = farH.xyz  / farH.w;
        float3 ro = nearP;
        float3 rd = normalize(farP - nearP);

        float3 boxMin = -U.volumeSize.xyz * 0.5;
        float3 boxMax =  U.volumeSize.xyz * 0.5;

        float t0, t1;
        if (!intersectBox(ro, rd, boxMin, boxMax, t0, t1)) {
            discard_fragment();
        }
        t0 = max(t0, 0.0);

        const int   STEPS    = 512;
        float       stepLen  = (t1 - t0) / float(STEPS);
        float3      pos      = ro + rd * t0;
        float3      stepVec  = rd * stepLen;

        float center  = U.windowAndMode.x;
        float width   = max(U.windowAndMode.y, 1.0e-4);
        float lo      = center - width * 0.5;
        int   mode    = int(U.windowAndMode.z + 0.5);

        bool  clipOn  = U.clipParams.x > 0.5;
        int   clipAx  = int(U.clipParams.y + 0.5);
        float clipPos = U.clipParams.z;
        bool  clipFlp = U.clipParams.w > 0.5;

        float maxVal = 0.0;
        float4 accum = float4(0.0);

        for (int i = 0; i < STEPS; ++i) {
            float3 coord = (pos - boxMin) / (boxMax - boxMin); // 0..1
            pos += stepVec;

            if (any(coord < float3(0.0)) || any(coord > float3(1.0))) {
                continue;
            }

            if (clipOn) {
                float c = (clipAx == 0) ? coord.x : (clipAx == 1 ? coord.y : coord.z);
                if (clipFlp ? (c < clipPos) : (c > clipPos)) {
                    continue;
                }
            }

            float v = vol.sample(s, coord).r;
            float w = clamp((v - lo) / width, 0.0, 1.0);

            if (mode == 0) {
                if (w > maxVal) maxVal = w;
            } else {
                float a = w * w * 0.06;
                accum.rgb += (1.0 - accum.a) * a * float3(w);
                accum.a   += (1.0 - accum.a) * a;
                if (accum.a > 0.97) break;
            }
        }

        if (mode == 0) {
            return float4(maxVal, maxVal, maxVal, 1.0);
        } else {
            return float4(accum.rgb, 1.0);
        }
    }
    """
}
