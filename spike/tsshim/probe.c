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
#include <dxgi1_6.h>

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

    // == deeper: the calls Unreal's D3D12 RHI makes at init, on the enumerated adapter rather
    // than the default one, plus the objects it creates before any frame (highball-db#48:
    // Hogwarts Legacy refuses DirectX 12 on macOS 15 while the device probe above is clean).
    say("== deeper (Unreal-style init on the enumerated adapter)");
    {
        typedef HRESULT (WINAPI *cf2_t)(UINT, REFIID, void **);
        HMODULE dxgi = LoadLibraryA("dxgi.dll");
        cf2_t cf2 = dxgi ? (cf2_t)GetProcAddress(dxgi, "CreateDXGIFactory2") : NULL;
        IDXGIFactory4 *fx = NULL;
        HRESULT r = cf2 ? cf2(0, &IID_IDXGIFactory4, (void **)&fx) : E_FAIL;
        say("CreateDXGIFactory2(IDXGIFactory4): 0x%08lx", (unsigned long)r);
        IDXGIAdapter1 *ad = NULL;
        if (SUCCEEDED(r) && fx) {
            IDXGIFactory6 *f6 = NULL;
            r = IDXGIFactory4_QueryInterface(fx, &IID_IDXGIFactory6, (void **)&f6);
            say("factory QI IDXGIFactory6: 0x%08lx", (unsigned long)r);
            if (SUCCEEDED(r) && f6) {
                r = IDXGIFactory6_EnumAdapterByGpuPreference(f6, 0, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, &IID_IDXGIAdapter1, (void **)&ad);
                say("EnumAdapterByGpuPreference(0, high performance): 0x%08lx", (unsigned long)r);
                IDXGIFactory6_Release(f6);
            }
            if (!ad) { r = IDXGIFactory4_EnumAdapters1(fx, 0, &ad); say("EnumAdapters1(0): 0x%08lx", (unsigned long)r); }
        }
        if (ad) {
            IDXGIAdapter3 *a3 = NULL; IDXGIAdapter4 *a4 = NULL;
            say("adapter QI IDXGIAdapter3: 0x%08lx", (unsigned long)IDXGIAdapter1_QueryInterface(ad, &IID_IDXGIAdapter3, (void **)&a3));
            if (a3) IDXGIAdapter3_Release(a3);
            say("adapter QI IDXGIAdapter4: 0x%08lx", (unsigned long)IDXGIAdapter1_QueryInterface(ad, &IID_IDXGIAdapter4, (void **)&a4));
            if (a4) IDXGIAdapter4_Release(a4);
            LARGE_INTEGER umd = {{0}};
            r = IDXGIAdapter1_CheckInterfaceSupport(ad, &IID_IDXGIDevice, &umd);
            say("adapter CheckInterfaceSupport(IDXGIDevice): 0x%08lx, driver %u.%u.%u.%u", (unsigned long)r,
                HIWORD(umd.HighPart), LOWORD(umd.HighPart), HIWORD(umd.LowPart), LOWORD(umd.LowPart));
            ID3D12Device *d = NULL;
            r = create((IUnknown *)ad, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&d);
            say("D3D12CreateDevice(adapter, 11_0): 0x%08lx", (unsigned long)r);
            if (SUCCEEDED(r) && d) {
                D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
                D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { 4, want, 0 };
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof fl);
                say("CheckFeatureSupport(FEATURE_LEVELS 12_1..11_0): 0x%08lx -> max 0x%x", (unsigned long)r, fl.MaxSupportedFeatureLevel);
                static const int SMS[] = { 0x66, 0x65, 0x60, 0x51 };
                for (int i = 0; i < 4; i++) {
                    D3D12_FEATURE_DATA_SHADER_MODEL sm = { (D3D_SHADER_MODEL)SMS[i] };
                    r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof sm);
                    say("CheckFeatureSupport(SHADER_MODEL ask 0x%x): 0x%08lx -> 0x%x", SMS[i], (unsigned long)r, sm.HighestShaderModel);
                }
                D3D12_FEATURE_DATA_ROOT_SIGNATURE rs = { D3D_ROOT_SIGNATURE_VERSION_1_1 };
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_ROOT_SIGNATURE, &rs, sizeof rs);
                say("CheckFeatureSupport(ROOT_SIGNATURE ask 1_1): 0x%08lx -> highest 0x%x", (unsigned long)r, rs.HighestVersion);
                D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof o);
                say("OPTIONS: 0x%08lx, DoublePrecision %d, MinPrecision 0x%x, TypedUAVLoad %d, ROVs %d, StdSwizzle64KB %d, CrossNodeSharing %d, CrossAdapterRowMajor %d, VPAndRTArrayIndex %d",
                    (unsigned long)r, o.DoublePrecisionFloatShaderOps, o.MinPrecisionSupport, o.TypedUAVLoadAdditionalFormats, o.ROVsSupported,
                    o.StandardSwizzle64KBSupported, o.CrossNodeSharingTier, o.CrossAdapterRowMajorTextureSupported, o.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation);
                D3D12_FEATURE_DATA_D3D12_OPTIONS2 o2 = {0};
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_D3D12_OPTIONS2, &o2, sizeof o2);
                say("OPTIONS2: 0x%08lx, DepthBoundsTest %d, ProgrammableSamplePositionsTier %d", (unsigned long)r, o2.DepthBoundsTestSupported, o2.ProgrammableSamplePositionsTier);
                D3D12_FEATURE_DATA_D3D12_OPTIONS4 o4 = {0};
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_D3D12_OPTIONS4, &o4, sizeof o4);
                say("OPTIONS4: 0x%08lx, Native16Bit %d, SharedResourceCompat %d", (unsigned long)r, o4.Native16BitShaderOpsSupported, o4.SharedResourceCompatibilityTier);
                D3D12_FEATURE_DATA_D3D12_OPTIONS6 o6 = {0};
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_D3D12_OPTIONS6, &o6, sizeof o6);
                say("OPTIONS6: 0x%08lx, VariableShadingRateTier %d, BackgroundProcessing %d", (unsigned long)r, o6.VariableShadingRateTier, o6.BackgroundProcessingSupported);
                D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT va = {0};
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_GPU_VIRTUAL_ADDRESS_SUPPORT, &va, sizeof va);
                say("GPU_VIRTUAL_ADDRESS_SUPPORT: 0x%08lx, per resource %u bits, per process %u bits", (unsigned long)r, va.MaxGPUVirtualAddressBitsPerResource, va.MaxGPUVirtualAddressBitsPerProcess);
                D3D12_FEATURE_DATA_FORMAT_SUPPORT fs = { DXGI_FORMAT_R8G8B8A8_UNORM, 0, 0 };
                r = ID3D12Device_CheckFeatureSupport(d, D3D12_FEATURE_FORMAT_SUPPORT, &fs, sizeof fs);
                say("FORMAT_SUPPORT(R8G8B8A8_UNORM): 0x%08lx, support1 0x%x, support2 0x%x", (unsigned long)r, fs.Support1, fs.Support2);
                static const struct { const IID *iid; const char *name; } DEVS[] = {
                    { &IID_ID3D12Device1, "ID3D12Device1" }, { &IID_ID3D12Device2, "ID3D12Device2" }, { &IID_ID3D12Device3, "ID3D12Device3" },
                    { &IID_ID3D12Device4, "ID3D12Device4" }, { &IID_ID3D12Device5, "ID3D12Device5" }, { &IID_ID3D12Device6, "ID3D12Device6" },
                    { &IID_ID3D12Device7, "ID3D12Device7" }, { &IID_ID3D12Device8, "ID3D12Device8" }, { &IID_ID3D12InfoQueue, "ID3D12InfoQueue" },
                };
                for (unsigned i = 0; i < sizeof DEVS / sizeof DEVS[0]; i++) {
                    IUnknown *u = NULL;
                    r = ID3D12Device_QueryInterface(d, DEVS[i].iid, (void **)&u);
                    say("device QI %s: 0x%08lx", DEVS[i].name, (unsigned long)r);
                    if (u) IUnknown_Release(u);
                }
                static const struct { D3D12_COMMAND_LIST_TYPE t; const char *name; } QUEUES[] = {
                    { D3D12_COMMAND_LIST_TYPE_DIRECT, "direct" }, { D3D12_COMMAND_LIST_TYPE_COMPUTE, "compute" }, { D3D12_COMMAND_LIST_TYPE_COPY, "copy" } };
                for (int i = 0; i < 3; i++) {
                    D3D12_COMMAND_QUEUE_DESC qd2 = { QUEUES[i].t, 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
                    ID3D12CommandQueue *q2 = NULL;
                    r = ID3D12Device_CreateCommandQueue(d, &qd2, &IID_ID3D12CommandQueue, (void **)&q2);
                    say("CreateCommandQueue(%s): 0x%08lx", QUEUES[i].name, (unsigned long)r);
                    if (q2) ID3D12CommandQueue_Release(q2);
                }
                ID3D12Fence *fence = NULL;
                r = ID3D12Device_CreateFence(d, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
                say("CreateFence: 0x%08lx", (unsigned long)r);
                if (fence) ID3D12Fence_Release(fence);
                ID3D12CommandAllocator *alloc = NULL;
                r = ID3D12Device_CreateCommandAllocator(d, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc);
                say("CreateCommandAllocator(direct): 0x%08lx", (unsigned long)r);
                if (alloc) {
                    ID3D12GraphicsCommandList *cl = NULL;
                    r = ID3D12Device_CreateCommandList(d, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&cl);
                    say("CreateCommandList(direct): 0x%08lx", (unsigned long)r);
                    if (cl) {
                        static const struct { const IID *iid; const char *name; } CLS[] = {
                            { &IID_ID3D12GraphicsCommandList1, "GraphicsCommandList1" }, { &IID_ID3D12GraphicsCommandList2, "GraphicsCommandList2" },
                            { &IID_ID3D12GraphicsCommandList3, "GraphicsCommandList3" }, { &IID_ID3D12GraphicsCommandList4, "GraphicsCommandList4" } };
                        for (int i = 0; i < 4; i++) {
                            IUnknown *u = NULL;
                            r = ID3D12GraphicsCommandList_QueryInterface(cl, CLS[i].iid, (void **)&u);
                            say("command list QI %s: 0x%08lx", CLS[i].name, (unsigned long)r);
                            if (u) IUnknown_Release(u);
                        }
                        ID3D12GraphicsCommandList_Release(cl);
                    }
                    ID3D12CommandAllocator_Release(alloc);
                }
                static const struct { D3D12_DESCRIPTOR_HEAP_TYPE t; UINT n; D3D12_DESCRIPTOR_HEAP_FLAGS f; const char *name; } HEAPS[] = {
                    { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1000000, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "CBV_SRV_UAV 1000000 shader visible" },
                    { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 65536, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "CBV_SRV_UAV 65536 shader visible" },
                    { D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2048, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, "SAMPLER 2048 shader visible" },
                    { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1024, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, "RTV 1024" },
                    { D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 256, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, "DSV 256" } };
                for (unsigned i = 0; i < sizeof HEAPS / sizeof HEAPS[0]; i++) {
                    D3D12_DESCRIPTOR_HEAP_DESC hd = { HEAPS[i].t, HEAPS[i].n, HEAPS[i].f, 0 };
                    ID3D12DescriptorHeap *h = NULL;
                    r = ID3D12Device_CreateDescriptorHeap(d, &hd, &IID_ID3D12DescriptorHeap, (void **)&h);
                    say("CreateDescriptorHeap(%s): 0x%08lx", HEAPS[i].name, (unsigned long)r);
                    if (h) ID3D12DescriptorHeap_Release(h);
                }
                {
                    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
                    D3D12_HEAP_PROPERTIES up = { D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
                    D3D12_RESOURCE_DESC buf = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, 65536, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE };
                    D3D12_RESOURCE_DESC tex = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 256, 256, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET };
                    D3D12_RESOURCE_DESC dep = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 256, 256, 1, 1, DXGI_FORMAT_D32_FLOAT, {1, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL };
                    D3D12_RESOURCE_DESC uav = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, 65536, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS };
                    struct { const D3D12_HEAP_PROPERTIES *h; const D3D12_RESOURCE_DESC *d; D3D12_RESOURCE_STATES s; const char *name; } RES[] = {
                        { &hp, &buf, D3D12_RESOURCE_STATE_COMMON, "default buffer 64K" }, { &up, &buf, D3D12_RESOURCE_STATE_GENERIC_READ, "upload buffer 64K" },
                        { &hp, &tex, D3D12_RESOURCE_STATE_RENDER_TARGET, "render target 256x256 RGBA8" }, { &hp, &dep, D3D12_RESOURCE_STATE_DEPTH_WRITE, "depth 256x256 D32" },
                        { &hp, &uav, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, "UAV buffer 64K" } };
                    for (unsigned i = 0; i < sizeof RES / sizeof RES[0]; i++) {
                        ID3D12Resource *res = NULL;
                        r = ID3D12Device_CreateCommittedResource(d, RES[i].h, D3D12_HEAP_FLAG_NONE, RES[i].d, RES[i].s, NULL, &IID_ID3D12Resource, (void **)&res);
                        say("CreateCommittedResource(%s): 0x%08lx", RES[i].name, (unsigned long)r);
                        if (res) ID3D12Resource_Release(res);
                    }
                    D3D12_HEAP_DESC hd = { 64 << 20, hp, 0, D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS };
                    ID3D12Heap *heap = NULL;
                    r = ID3D12Device_CreateHeap(d, &hd, &IID_ID3D12Heap, (void **)&heap);
                    say("CreateHeap(64 MB buffers): 0x%08lx", (unsigned long)r);
                    if (heap) ID3D12Heap_Release(heap);
                }
                {
                    typedef HRESULT (WINAPI *ser_t)(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *, ID3DBlob **, ID3DBlob **);
                    ser_t ser = (ser_t)GetProcAddress(m, "D3D12SerializeVersionedRootSignature");
                    D3D12_VERSIONED_ROOT_SIGNATURE_DESC vd;
                    memset(&vd, 0, sizeof vd);
                    vd.Version = D3D_ROOT_SIGNATURE_VERSION_1_1;
                    vd.Desc_1_1.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
                    ID3DBlob *blob = NULL, *err = NULL;
                    r = ser ? ser(&vd, &blob, &err) : E_NOTIMPL;
                    say("D3D12SerializeVersionedRootSignature(1_1, empty): 0x%08lx", (unsigned long)r);
                    if (SUCCEEDED(r) && blob) {
                        ID3D12RootSignature *rsig = NULL;
                        r = ID3D12Device_CreateRootSignature(d, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)&rsig);
                        say("CreateRootSignature: 0x%08lx", (unsigned long)r);
                        if (rsig) ID3D12RootSignature_Release(rsig);
                        ID3D10Blob_Release(blob);
                    }
                    if (err) ID3D10Blob_Release(err);
                }
                ID3D12Device_Release(d);
            }
            IDXGIAdapter1_Release(ad);
        }
        if (fx) IDXGIFactory4_Release(fx);
    }
    say("dx12probe: done");
    return 0;
}
