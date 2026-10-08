// A constant colour, compiled at ps_6_6 and ps_6_7. Expected pixel 64,127 or 128,191,255.
#define RS "DescriptorTable(SRV(t0, numDescriptors=3), UAV(u0, numDescriptors=2)), DescriptorTable(Sampler(s0, numDescriptors=2))"
[RootSignature(RS)]
float4 main(float4 pos : SV_Position) : SV_Target { return float4(0.25, 0.5, 0.75, 1); }
