// Control for quad operations in compute (Shader Model 6.6): QuadReadAcrossX swaps lane pairs.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
[numthreads(4, 4, 1)]
[RootSignature(RS)]
void main(uint3 gid : SV_GroupThreadID) { uint flat = gid.y * 4 + gid.x; outb[flat] = QuadReadAcrossX(flat); }
