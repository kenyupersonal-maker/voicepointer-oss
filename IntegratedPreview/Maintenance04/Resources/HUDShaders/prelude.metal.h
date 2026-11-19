// HUD shader prelude (Metal). Skin files are written in a GLSL/MSL common dialect.
#include <metal_stdlib>
using namespace metal;
#define vec2 float2
#define vec3 float3
#define vec4 float4
#define mat2 float2x2
#define mat3 float3x3
#define UARG constant U&
#define atan2_(y, x) atan2(y, x)
#define inversesqrt rsqrt
#define PI 3.14159265
#define TAU 6.28318531
struct U {
    float2 res; float2 anchor;
    float scale; float time; float phase; float level; float peak;
    float aim; float aimRaw; float appear; float send; float cancel; float fade;
    float dark; float coreOnly; float reduce; float contrast; float seed;
};
inline float mod(float x, float y) { return x - y * floor(x / y); }
inline float2 mod(float2 x, float y) { return x - y * floor(x / y); }
inline float3 mod(float3 x, float y) { return x - y * floor(x / y); }
struct VOut { float4 pos [[position]]; };
vertex VOut v_full(uint vid [[vertex_id]]) {
    float2 xy = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o; o.pos = float4(xy * 2.0 - 1.0, 0.0, 1.0); return o;
}
struct PV { float4 pos [[position]]; float size [[point_size]]; float4 color; };
fragment float4 f_points(PV in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    return in.color * (1.0 - smoothstep(0.5, 1.0, d));
}
// Tunable skin parameters (see skin_params.json): Metal function constants, set per pipeline from the user's settings.
#define PARAM_F(name, idx) constant float name [[function_constant(idx)]];
#define PARAM_V3(name, idx) constant float3 name [[function_constant(idx)]];
