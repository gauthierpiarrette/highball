// Shader Model 6.7: sampling an integer texture (point filter). uv (0.625, 0.125) is texel (2,0): expected 3.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
Texture2D<uint> utex : register(t0);
SamplerState s0 : register(s0);
[numthreads(1, 1, 1)]
[RootSignature(RS)]
void main() {
    outb[0] = utex.SampleLevel(s0, float2(0.625, 0.125), 0);
    outb[1] = utex.SampleLevel(s0, float2(0.875, 0.875), 0);   // texel (3,3): 16
}
