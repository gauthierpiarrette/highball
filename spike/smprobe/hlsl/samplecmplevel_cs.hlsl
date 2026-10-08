// Shader Model 6.7: SampleCmpLevel. The float texture holds (y*4+x)/16, the sampler compares LESS.
// texel (2,0) = 0.125: ref 0.0625 < 0.125 -> 1, ref 0.5 < 0.125 -> 0. Expected 1, 0.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
RWStructuredBuffer<uint> outb : register(u0);
Texture2D<float> ftex : register(t1);
SamplerComparisonState sc : register(s1);
[numthreads(1, 1, 1)]
[RootSignature(RS)]
void main() {
    float a = ftex.SampleCmpLevel(sc, float2(0.625, 0.125), 0.0625, 0);
    float b = ftex.SampleCmpLevel(sc, float2(0.625, 0.125), 0.5, 0);
    outb[0] = a > 0.5 ? 1 : 0;
    outb[1] = b > 0.5 ? 1 : 0;
}
