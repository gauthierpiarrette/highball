// Shader Model 6.7: QuadAny / QuadAll in a compute shader (quads are 2x2 in a 4x4 group).
// Expected: x < 2 -> 3, x >= 2 -> 2.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
[numthreads(4, 4, 1)]
[RootSignature(RS)]
void main(uint3 gid : SV_GroupThreadID) {
    uint flat = gid.y * 4 + gid.x;
    uint v = 0;
    if (QuadAny(gid.x == 0)) v |= 1;
    if (QuadAll(gid.x < 4)) v |= 2;
    if (QuadAll(gid.x == 0)) v |= 4;
    if (QuadAny(gid.x == 9)) v |= 8;
    outb[flat] = v;
}
