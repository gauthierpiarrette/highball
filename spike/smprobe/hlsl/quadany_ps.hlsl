// Shader Model 6.7: QuadAny in a pixel shader. Pixel (0,0) is in a quad with x < 2 -> red; pixel (3,3) -> blue.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
[RootSignature(RS)]
float4 main(float4 pos : SV_Position) : SV_Target {
    return QuadAny(pos.x < 2.0) ? float4(1, 0, 0, 1) : float4(0, 0, 1, 1);
}
