// Shader Model 6.7: GatherRaw on an integer texture. The 4x4 R32_UINT texture holds y*4+x+1.
// At uv (0.5, 0.5) the gather footprint is texels (1,1) (2,1) (1,2) (2,2): expected x=10 y=11 z=7 w=6.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
Texture2D<uint> utex : register(t0);
SamplerState s0 : register(s0);
[numthreads(1, 1, 1)]
[RootSignature(RS)]
void main() {
    uint4 g = utex.GatherRaw(s0, float2(0.5, 0.5));
    outb[0] = g.x; outb[1] = g.y; outb[2] = g.z; outb[3] = g.w;
    uint4 h = utex.Gather(s0, float2(0.5, 0.5));
    outb[4] = h.x; outb[5] = h.y; outb[6] = h.z; outb[7] = h.w;
}
