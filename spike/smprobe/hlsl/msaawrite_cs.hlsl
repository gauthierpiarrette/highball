// Shader Model 6.7: writable multisampled texture (RWTexture2DMS). Writes sample 1 of every texel, then marks
// the buffer so the dispatch is known to have run. Expected 7 x 16.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
RWTexture2DMS<float4, 4> msaa : register(u1);
[numthreads(4, 4, 1)]
[RootSignature(RS)]
void main(uint3 gid : SV_GroupThreadID) {
    msaa.sample[1][gid.xy] = float4(1, 0, 0, 1);
    outb[gid.y * 4 + gid.x] = 7;
}
