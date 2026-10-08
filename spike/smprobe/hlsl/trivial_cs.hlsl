// Control and ceiling: the same compute shader compiled at cs_6_6, cs_6_7, cs_6_8 and cs_6_9.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
[numthreads(16, 1, 1)]
[RootSignature(RS)]
void main(uint tid : SV_DispatchThreadID) { outb[tid] = tid * 2 + 1; }
