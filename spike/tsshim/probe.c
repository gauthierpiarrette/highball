// dx12probe: which d3d12.dll a process gets, whether a D3D12 device comes up, and what the
// timestamp frequency is. Built by Scripts/build-tsshim.sh --probe into the scratchpad; run in a
// bottle with `highball run <bottle> <unix path> --renderer d3dmetal --verbose`.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static void say(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap); fputc('\n', stdout); fflush(stdout);
}

int main(void) {
    char path[MAX_PATH];
    say("dx12probe: LoadLibrary(d3d12.dll)");
    HMODULE m = LoadLibraryA("d3d12.dll");
    if (!m) { say("  FAILED, error %lu", GetLastError()); return 1; }
    GetModuleFileNameA(m, path, sizeof path);
    say("  module: %s", path);
    HMODULE real = GetModuleHandleA("apd12.dll");
    if (real) { GetModuleFileNameA(real, path, sizeof path); say("  shim active, real: %s", path); }
    else say("  no apd12.dll in the process (shim absent or idle)");

    typedef HRESULT (WINAPI *create_t)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    create_t create = (create_t)GetProcAddress(m, "D3D12CreateDevice");
    if (!create) { say("  no D3D12CreateDevice export, error %lu", GetLastError()); return 2; }

    // Feature levels a DirectX 12 game asks for. GTA V Enhanced quits with ERR_GFX_D3D_NOD3D12
    // when none it accepts comes back, so print every one.
    static const struct { D3D_FEATURE_LEVEL fl; const char *name; } LEVELS[] = {
        { D3D_FEATURE_LEVEL_11_0, "11_0" }, { D3D_FEATURE_LEVEL_11_1, "11_1" },
        { D3D_FEATURE_LEVEL_12_0, "12_0" }, { D3D_FEATURE_LEVEL_12_1, "12_1" },
    };
    for (int i = 0; i < 4; i++) {
        ID3D12Device *probe = NULL;
        HRESULT r = create(NULL, LEVELS[i].fl, &IID_ID3D12Device, (void **)&probe);
        say("  feature level %s: 0x%08lx%s", LEVELS[i].name, (unsigned long)r, SUCCEEDED(r) ? " ok" : "");
        if (probe) ID3D12Device_Release(probe);
    }

    // The Agility SDK path a modern game takes (GTA V Enhanced): D3D12GetInterface ->
    // ID3D12SDKConfiguration1 -> CreateDeviceFactory(its SDK version) -> ID3D12DeviceFactory::CreateDevice.
    typedef HRESULT (WINAPI *getif_t)(REFCLSID, REFIID, void **);
    getif_t getif = (getif_t)GetProcAddress(m, "D3D12GetInterface");
    say("D3D12GetInterface export: %s", getif ? "present" : "MISSING (Agility SDK games quit here)");
    if (getif) {
        ID3D12SDKConfiguration1 *cfg = NULL;
        HRESULT r = getif(&CLSID_D3D12SDKConfiguration, &IID_ID3D12SDKConfiguration1, (void **)&cfg);
        say("  SDKConfiguration1: 0x%08lx", (unsigned long)r);
        if (SUCCEEDED(r) && cfg) {
            ID3D12DeviceFactory *fac = NULL;
            r = ID3D12SDKConfiguration1_CreateDeviceFactory(cfg, 611, ".\\D3D12-REDIST\\", &IID_ID3D12DeviceFactory, (void **)&fac);
            say("  CreateDeviceFactory(611): 0x%08lx", (unsigned long)r);
            if (SUCCEEDED(r) && fac) {
                ID3D12Device *d = NULL;
                r = ID3D12DeviceFactory_CreateDevice(fac, NULL, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&d);
                say("  factory CreateDevice(12_0): 0x%08lx%s", (unsigned long)r, SUCCEEDED(r) ? " ok" : "");
                if (d) ID3D12Device_Release(d);
                ID3D12DeviceFactory_Release(fac);
            }
            ID3D12SDKConfiguration1_Release(cfg);
        }
    }

    ID3D12Device *dev = NULL;
    HRESULT hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    say("D3D12CreateDevice(11_0): 0x%08lx", (unsigned long)hr);
    if (FAILED(hr) || !dev) return 3;

    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof o)))
        say("options: ResourceBindingTier %d, TiledResourcesTier %d, ConservativeRasterizationTier %d, ResourceHeapTier %d",
            o.ResourceBindingTier, o.TiledResourcesTier, o.ConservativeRasterizationTier, o.ResourceHeapTier);
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { D3D_SHADER_MODEL_6_6 };
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof sm)))
        say("shader model: 0x%x", sm.HighestShaderModel);
    // The capability checks a modern DirectX 12 game makes right after creating its device.
    // GTA V Enhanced creates a device fine under D3DMetal and still quits with ERR_GFX_D3D_NOD3D12,
    // so the refusal is one of these. Printed for every renderer so they can be compared.
#define OPT(n, field, fmt, ...) do { \
        D3D12_FEATURE_DATA_D3D12_OPTIONS##n o##n = {0}; \
        HRESULT r = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS##n, &o##n, sizeof o##n); \
        if (SUCCEEDED(r)) say("options" #n ": " fmt, __VA_ARGS__); \
        else say("options" #n ": unsupported query 0x%08lx", (unsigned long)r); \
    } while (0)
    OPT(1, , "WaveOps %d, WaveLaneCountMin %u", o1.WaveOps, o1.WaveLaneCountMin);
    OPT(3, , "CopyQueueTimestampQueriesSupported %d, WriteBufferImmediateSupport %d, BarycentricsSupported %d",
        o3.CopyQueueTimestampQueriesSupported, o3.WriteBufferImmediateSupportFlags, o3.BarycentricsSupported);
    OPT(5, , "RaytracingTier %d, RenderPassesTier %d", o5.RaytracingTier, o5.RenderPassesTier);
    OPT(7, , "MeshShaderTier %d, SamplerFeedbackTier %d", o7.MeshShaderTier, o7.SamplerFeedbackTier);
    OPT(9, , "MeshShaderPipelineStatsSupported %d, AtomicInt64OnGroupSharedSupported %d",
        o9.MeshShaderPipelineStatsSupported, o9.AtomicInt64OnGroupSharedSupported);
    OPT(12, , "EnhancedBarriersSupported %d, RelaxedFormatCastingSupported %d",
        o12.EnhancedBarriersSupported, o12.RelaxedFormatCastingSupported);
    OPT(13, , "UnrestrictedBufferTextureCopyPitchSupported %d, AlphaBlendFactorSupported %d",
        o13.UnrestrictedBufferTextureCopyPitchSupported, o13.AlphaBlendFactorSupported);

    D3D12_FEATURE_DATA_ARCHITECTURE arch = {0};
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_ARCHITECTURE, &arch, sizeof arch)))
        say("architecture: UMA %d, CacheCoherentUMA %d", arch.UMA, arch.CacheCoherentUMA);

    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
    ID3D12CommandQueue *q = NULL;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    say("CreateCommandQueue: 0x%08lx", (unsigned long)hr);
    if (SUCCEEDED(hr) && q) {
        UINT64 f = 0;
        hr = ID3D12CommandQueue_GetTimestampFrequency(q, &f);
        say("GetTimestampFrequency: 0x%08lx -> %llu Hz", (unsigned long)hr, (unsigned long long)f);
        ID3D12CommandQueue_Release(q);
    }
    ID3D12Device_Release(dev);
    // DXGI: the adapter the game enumerates, and whether tearing is offered.
    {
        typedef HRESULT (WINAPI *cf2_t)(UINT, REFIID, void **);
        HMODULE dxgi = LoadLibraryA("dxgi.dll");
        cf2_t cf2 = dxgi ? (cf2_t)GetProcAddress(dxgi, "CreateDXGIFactory2") : NULL;
        IDXGIFactory4 *fx = NULL;
        if (cf2 && SUCCEEDED(cf2(0, &IID_IDXGIFactory4, (void **)&fx)) && fx) {
            IDXGIAdapter1 *ad = NULL;
            for (UINT i = 0; IDXGIFactory4_EnumAdapters1(fx, i, &ad) == S_OK; i++) {
                DXGI_ADAPTER_DESC1 d = {0};
                IDXGIAdapter1_GetDesc1(ad, &d);
                say("adapter %u: %ls, vendor 0x%04x, device 0x%04x, video memory %llu MB, flags 0x%x",
                    i, d.Description, d.VendorId, d.DeviceId,
                    (unsigned long long)(d.DedicatedVideoMemory >> 20), d.Flags);
                IDXGIAdapter1_Release(ad);
            }
            IDXGIFactory4_Release(fx);
        } else say("dxgi: no factory");
    }
    say("dx12probe: done");
    return 0;
}
