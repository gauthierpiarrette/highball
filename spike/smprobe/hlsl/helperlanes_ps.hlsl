// Shader Model 6.7: wave operations that include helper lanes. The value is hardware dependent, only the
// pipeline creation and the draw are checked.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
[WaveOpsIncludeHelperLanes]
[RootSignature(RS)]
float4 main(float4 pos : SV_Position) : SV_Target {
    uint n = WaveActiveCountBits(true);
    return float4(n / 64.0, WaveIsFirstLane() ? 1 : 0, 0, 1);
}
