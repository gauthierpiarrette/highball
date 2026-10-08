// Shader Model 6.7: programmable (non-immediate) offsets for Load and SampleLevel. Expected 1,2,3,4,1,2,3,4.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
Texture2D<uint> utex : register(t0);
SamplerState s0 : register(s0);
[numthreads(4, 1, 1)]
[RootSignature(RS)]
void main(uint tid : SV_DispatchThreadID) {
    int2 off = int2(tid, 0);
    outb[tid] = utex.Load(int3(0, 0, 0), off);
    outb[4 + tid] = utex.SampleLevel(s0, float2(0.125, 0.125), 0, off);
}
