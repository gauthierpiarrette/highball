// smprobe: does a Direct3D 12 runtime run Shader Model 6.7 shaders, whatever it answers to
// CheckFeatureSupport(SHADER_MODEL)? Written for D3DMetal, which answers 6.6 and makes Microsoft
// Flight Simulator 2024 refuse to start (highball-db#6).
//
// The shaders in hlsl/ are compiled ahead by the official dxc (tests.txt, compile.sh) into
// <dir>/<name>.dxil. For each compute test the probe creates the pipeline state, dispatches one
// group and reads the UAV buffer back, so the answer is the real output, not only an HRESULT.
// Graphics tests draw a full-screen triangle into a 4x4 target and read two pixels back.
//
// Build (mingw on the M1): x86_64-w64-mingw32-gcc -O2 -Wall -o smprobe.exe smprobe.c -ld3d12 -ldxgi -luuid
// Run (in a bottle): highball run <bottle> /path/smprobe.exe --renderer d3dmetal --verbose -- Z:\path\to\dxil
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static void say(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap); fputc('\n', stdout); fflush(stdout);
}

#ifndef D3D12_UAV_DIMENSION_TEXTURE2DMS
#define D3D12_UAV_DIMENSION_TEXTURE2DMS 6
#endif

// ---- the test table (keep in step with tests.txt) ----------------------------------------------
// expect: values the first n entries of the UAV buffer must hold (-1 = do not check that entry).
typedef struct { const char *name; const char *what; int n; int expect[16]; } ComputeTest;
static const ComputeTest COMPUTE[] = {
    { "cs66_trivial", "control, SM 6.6", 16, {1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31} },
    { "cs67_trivial", "the same shader at SM 6.7 (DXIL 1.7)", 16, {1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31} },
    { "cs68_trivial", "the same shader at SM 6.8 (DXIL 1.8)", 16, {1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31} },
    { "cs69_trivial", "the same shader at SM 6.9 (DXIL 1.9)", 16, {1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31} },
    { "cs66_quadread", "control, QuadReadAcrossX at SM 6.6", 16, {1,0,3,2,5,4,7,6,9,8,11,10,13,12,15,14} },
    { "cs67_quadany", "QuadAny / QuadAll in compute (SM 6.7)", 16, {3,3,2,2,3,3,2,2,3,3,2,2,3,3,2,2} },
    { "cs67_gatherraw", "GatherRaw on R32_UINT (SM 6.7), then Gather", 8, {10,11,7,6,10,11,7,6} },
    { "cs67_intsample", "SampleLevel on an integer texture (SM 6.7)", 2, {3,16} },
    { "cs67_samplecmplevel", "SampleCmpLevel (SM 6.7)", 2, {1,0} },
    { "cs67_progoffset", "programmable offsets for Load and SampleLevel (SM 6.7)", 8, {1,2,3,4,1,2,3,4} },
    { "cs67_msaawrite", "RWTexture2DMS write (SM 6.7, needs WriteableMSAATextures)", 16, {7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7} },
};
typedef struct { const char *vs, *ps; const char *what; int p00[4]; int p33[4]; } GraphicsTest;
static const GraphicsTest GRAPHICS[] = {
    { "vs66_fullscreen", "ps66_flat", "control, SM 6.6 vertex + pixel", {64,-1,191,255}, {64,-1,191,255} },
    { "vs67_fullscreen", "ps67_flat", "SM 6.7 vertex + pixel", {64,-1,191,255}, {64,-1,191,255} },
    { "vs67_fullscreen", "ps67_quadany", "QuadAny in a pixel shader (SM 6.7)", {255,0,0,255}, {0,0,255,255} },
    { "vs67_fullscreen", "ps67_helperlanes", "wave ops including helper lanes (SM 6.7)", {-1,-1,-1,255}, {-1,-1,-1,255} },
};

// ---- helpers ---------------------------------------------------------------------------------
static char dxil_dir[MAX_PATH];
static void *load_blob(const char *name, SIZE_T *size) {
    char path[MAX_PATH]; FILE *f; void *p; long n;
    snprintf(path, sizeof path, "%s\\%s.dxil", dxil_dir, name);
    f = fopen(path, "rb"); if (!f) { say("  %s: cannot open %s", name, path); return NULL; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    p = malloc(n); if (fread(p, 1, n, f) != (size_t)n) { fclose(f); free(p); return NULL; }
    fclose(f); *size = n; return p;
}
// The DXIL container: the "DXIL" part starts with a program header whose second dword holds the
// shader model: (kind << 16) | (major << 4) | minor. Printed so the blob's model is a measured fact.
static void describe_blob(const char *name, const void *blob, SIZE_T size) {
    const unsigned char *b = blob; UINT32 parts, i; const UINT32 *offs;
    if (size < 32 || memcmp(b, "DXBC", 4)) { say("  %s: not a DXBC container (%lu bytes)", name, (unsigned long)size); return; }
    parts = *(const UINT32 *)(b + 28); offs = (const UINT32 *)(b + 32);
    for (i = 0; i < parts && (32 + 4 * i + 4) <= size; i++) {
        const unsigned char *part = b + offs[i];
        if (offs[i] + 8 + 8 > size) break;
        if (!memcmp(part, "DXIL", 4)) {
            UINT32 ver = *(const UINT32 *)(part + 8);
            UINT32 dxil = *(const UINT32 *)(part + 8 + 12);
            say("  %s: %lu bytes, shader model %u_%u (kind %u), DXIL %u.%u", name, (unsigned long)size,
                (ver >> 4) & 0xf, ver & 0xf, ver >> 16, (dxil >> 8) & 0xff, dxil & 0xff);
            return;
        }
    }
    say("  %s: %lu bytes, no DXIL part found", name, (unsigned long)size);
}

static ID3D12Device *dev; static ID3D12CommandQueue *queue; static ID3D12CommandAllocator *alloc; static ID3D12GraphicsCommandList *list;
static ID3D12Fence *fence; static HANDLE fence_event; static UINT64 fence_value;
static ID3D12DescriptorHeap *res_heap, *samp_heap, *rtv_heap;
static ID3D12Resource *utex, *ftex, *uav_buf, *readback, *zero_upload, *msaa_tex, *rt_tex, *rt_readback;
static ID3D12RootSignature *rootsig;
static int msaa_ok;

static HRESULT wait_gpu(const char *what) {
    HRESULT hr; UINT64 v = ++fence_value; DWORD w;
    hr = ID3D12CommandQueue_Signal(queue, fence, v); if (FAILED(hr)) { say("  Signal: 0x%08lx", (unsigned long)hr); return hr; }
    if (ID3D12Fence_GetCompletedValue(fence) < v) {
        ID3D12Fence_SetEventOnCompletion(fence, v, fence_event);
        w = WaitForSingleObject(fence_event, 20000);
        if (w != WAIT_OBJECT_0) { say("  %s: the GPU did not finish within 20 s (device removed reason 0x%08lx)", what, (unsigned long)ID3D12Device_GetDeviceRemovedReason(dev)); return E_FAIL; }
    }
    return S_OK;
}
static HRESULT submit(const char *what) {
    HRESULT hr = ID3D12GraphicsCommandList_Close(list);
    if (FAILED(hr)) { say("  %s: Close: 0x%08lx", what, (unsigned long)hr); return hr; }
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    return wait_gpu(what);
}
static HRESULT begin(void) {
    HRESULT hr = ID3D12CommandAllocator_Reset(alloc); if (FAILED(hr)) return hr;
    return ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
}
static void barrier(ID3D12Resource *r, D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to) {
    D3D12_RESOURCE_BARRIER b; memset(&b, 0, sizeof b);
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; b.Transition.pResource = r;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES; b.Transition.StateBefore = from; b.Transition.StateAfter = to;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}
static ID3D12Resource *make_buffer(D3D12_HEAP_TYPE type, UINT64 bytes, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state, const char *what) {
    D3D12_HEAP_PROPERTIES hp = { type, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
    D3D12_RESOURCE_DESC d = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, bytes, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, flags };
    ID3D12Resource *r = NULL;
    HRESULT hr = ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &d, state, NULL, &IID_ID3D12Resource, (void **)&r);
    if (FAILED(hr)) say("  %s: CreateCommittedResource 0x%08lx", what, (unsigned long)hr);
    return r;
}
static ID3D12Resource *make_tex(DXGI_FORMAT fmt, UINT w, UINT h, UINT samples, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state, const char *what) {
    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
    D3D12_RESOURCE_DESC d = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, w, h, 1, 1, fmt, {samples, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, flags };
    ID3D12Resource *r = NULL;
    HRESULT hr = ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &d, state, NULL, &IID_ID3D12Resource, (void **)&r);
    say("  %s: CreateCommittedResource 0x%08lx", what, (unsigned long)hr);
    return r;
}
// Fill a 4x4 32-bit texture from CPU memory through an upload buffer, then move it to a shader-read state.
static HRESULT upload_tex(ID3D12Resource *tex, const void *texels, UINT bpp) {
    D3D12_RESOURCE_DESC d; D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT rows; UINT64 rowbytes, total; ID3D12Resource *up; void *p; HRESULT hr; UINT y;
    D3D12_TEXTURE_COPY_LOCATION dst, src;
    d = ID3D12Resource_GetDesc(tex);
    ID3D12Device_GetCopyableFootprints(dev, &d, 0, 1, 0, &fp, &rows, &rowbytes, &total);
    up = make_buffer(D3D12_HEAP_TYPE_UPLOAD, total, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_GENERIC_READ, "texture upload"); if (!up) return E_FAIL;
    hr = ID3D12Resource_Map(up, 0, NULL, &p); if (FAILED(hr)) return hr;
    for (y = 0; y < rows; y++) memcpy((char *)p + fp.Offset + y * fp.Footprint.RowPitch, (const char *)texels + y * 4 * bpp, 4 * bpp);
    ID3D12Resource_Unmap(up, 0, NULL);
    hr = begin(); if (FAILED(hr)) return hr;
    memset(&dst, 0, sizeof dst); dst.pResource = tex; dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; dst.SubresourceIndex = 0;
    memset(&src, 0, sizeof src); src.pResource = up; src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = fp;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    barrier(tex, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    hr = submit("texture upload");
    ID3D12Resource_Release(up);
    return hr;
}

static D3D12_CPU_DESCRIPTOR_HANDLE cpu_handle(ID3D12DescriptorHeap *h, D3D12_DESCRIPTOR_HEAP_TYPE t, UINT i) {
    D3D12_CPU_DESCRIPTOR_HANDLE c = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(h);
    c.ptr += (SIZE_T)i * ID3D12Device_GetDescriptorHandleIncrementSize(dev, t); return c;
}
static D3D12_GPU_DESCRIPTOR_HANDLE gpu_handle(ID3D12DescriptorHeap *h, D3D12_DESCRIPTOR_HEAP_TYPE t, UINT i) {
    D3D12_GPU_DESCRIPTOR_HANDLE g = ID3D12DescriptorHeap_GetGPUDescriptorHandleForHeapStart(h);
    g.ptr += (UINT64)i * ID3D12Device_GetDescriptorHandleIncrementSize(dev, t); return g;
}

// ---- setup -----------------------------------------------------------------------------------
static int setup(void) {
    HRESULT hr; D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
    D3D12_DESCRIPTOR_HEAP_DESC hd; UINT32 utexels[16]; float ftexels[16]; int i;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue); if (FAILED(hr)) { say("CreateCommandQueue 0x%08lx", (unsigned long)hr); return 0; }
    hr = ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc); if (FAILED(hr)) return 0;
    hr = ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list); if (FAILED(hr)) return 0;
    ID3D12GraphicsCommandList_Close(list);
    hr = ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence); if (FAILED(hr)) return 0;
    fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);

    memset(&hd, 0, sizeof hd); hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.NumDescriptors = 8; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    hr = ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&res_heap); if (FAILED(hr)) { say("resource heap 0x%08lx", (unsigned long)hr); return 0; }
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER; hd.NumDescriptors = 2;
    hr = ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&samp_heap); if (FAILED(hr)) { say("sampler heap 0x%08lx", (unsigned long)hr); return 0; }
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 1; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    hr = ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap); if (FAILED(hr)) { say("rtv heap 0x%08lx", (unsigned long)hr); return 0; }

    utex = make_tex(DXGI_FORMAT_R32_UINT, 4, 4, 1, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, "4x4 R32_UINT texture"); if (!utex) return 0;
    ftex = make_tex(DXGI_FORMAT_R32_FLOAT, 4, 4, 1, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, "4x4 R32_FLOAT texture"); if (!ftex) return 0;
    for (i = 0; i < 16; i++) { utexels[i] = i + 1; ftexels[i] = i / 16.0f; }
    if (FAILED(upload_tex(utex, utexels, 4)) || FAILED(upload_tex(ftex, ftexels, 4))) { say("texture upload failed"); return 0; }
    uav_buf = make_buffer(D3D12_HEAP_TYPE_DEFAULT, 1024, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, "UAV buffer"); if (!uav_buf) return 0;
    readback = make_buffer(D3D12_HEAP_TYPE_READBACK, 1024, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, "readback buffer"); if (!readback) return 0;
    zero_upload = make_buffer(D3D12_HEAP_TYPE_UPLOAD, 1024, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_GENERIC_READ, "zero buffer"); if (!zero_upload) return 0;
    { void *p; if (SUCCEEDED(ID3D12Resource_Map(zero_upload, 0, NULL, &p))) { memset(p, 0xEE, 1024); ID3D12Resource_Unmap(zero_upload, 0, NULL); } }
    msaa_tex = make_tex(DXGI_FORMAT_R8G8B8A8_UNORM, 4, 4, 4, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, "4x4 4-sample R8G8B8A8 texture with UAV (writable MSAA)");
    msaa_ok = msaa_tex != NULL;
    rt_tex = make_tex(DXGI_FORMAT_R8G8B8A8_UNORM, 4, 4, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET, "4x4 R8G8B8A8 render target"); if (!rt_tex) return 0;
    rt_readback = make_buffer(D3D12_HEAP_TYPE_READBACK, 4096, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, "render target readback"); if (!rt_readback) return 0;

    {   // views: t0 utex, t1 ftex, t2 ftex again (no null descriptors), u0 the buffer, u1 the MSAA texture
        D3D12_SHADER_RESOURCE_VIEW_DESC s; D3D12_UNORDERED_ACCESS_VIEW_DESC u; D3D12_SAMPLER_DESC sd; D3D12_RENDER_TARGET_VIEW_DESC rv;
        memset(&s, 0, sizeof s); s.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; s.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; s.Texture2D.MipLevels = 1;
        s.Format = DXGI_FORMAT_R32_UINT; ID3D12Device_CreateShaderResourceView(dev, utex, &s, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 0));
        s.Format = DXGI_FORMAT_R32_FLOAT; ID3D12Device_CreateShaderResourceView(dev, ftex, &s, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1));
        ID3D12Device_CreateShaderResourceView(dev, ftex, &s, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2));
        memset(&u, 0, sizeof u); u.Format = DXGI_FORMAT_UNKNOWN; u.ViewDimension = D3D12_UAV_DIMENSION_BUFFER; u.Buffer.NumElements = 256; u.Buffer.StructureByteStride = 4;
        ID3D12Device_CreateUnorderedAccessView(dev, uav_buf, NULL, &u, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 3));
        if (msaa_ok) {
            memset(&u, 0, sizeof u); u.Format = DXGI_FORMAT_R8G8B8A8_UNORM; u.ViewDimension = (D3D12_UAV_DIMENSION)D3D12_UAV_DIMENSION_TEXTURE2DMS;
            ID3D12Device_CreateUnorderedAccessView(dev, msaa_tex, NULL, &u, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 4));
            say("  UAV on the multisampled texture created (no HRESULT from CreateUnorderedAccessView)");
        } else {
            memset(&u, 0, sizeof u); u.Format = DXGI_FORMAT_UNKNOWN; u.ViewDimension = D3D12_UAV_DIMENSION_BUFFER; u.Buffer.NumElements = 256; u.Buffer.StructureByteStride = 4;
            ID3D12Device_CreateUnorderedAccessView(dev, uav_buf, NULL, &u, cpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 4));
        }
        memset(&sd, 0, sizeof sd); sd.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT; sd.AddressU = sd.AddressV = sd.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP; sd.MaxLOD = D3D12_FLOAT32_MAX;
        ID3D12Device_CreateSampler(dev, &sd, cpu_handle(samp_heap, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 0));
        sd.Filter = D3D12_FILTER_COMPARISON_MIN_MAG_MIP_POINT; sd.ComparisonFunc = D3D12_COMPARISON_FUNC_LESS;
        ID3D12Device_CreateSampler(dev, &sd, cpu_handle(samp_heap, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 1));
        memset(&rv, 0, sizeof rv); rv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rv.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D;
        ID3D12Device_CreateRenderTargetView(dev, rt_tex, &rv, cpu_handle(rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 0));
    }
    {   // root signature: table 0 = t0..t2 + u0..u1, table 1 = s0..s1
        D3D12_DESCRIPTOR_RANGE1 r0[2], r1[1]; D3D12_ROOT_PARAMETER1 prm[2]; D3D12_VERSIONED_ROOT_SIGNATURE_DESC vd; ID3DBlob *blob = NULL, *err = NULL;
        typedef HRESULT (WINAPI *ser_t)(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *, ID3DBlob **, ID3DBlob **);
        ser_t ser = (ser_t)GetProcAddress(GetModuleHandleA("d3d12.dll"), "D3D12SerializeVersionedRootSignature");
        memset(r0, 0, sizeof r0); memset(r1, 0, sizeof r1); memset(prm, 0, sizeof prm); memset(&vd, 0, sizeof vd);
        r0[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; r0[0].NumDescriptors = 3; r0[0].OffsetInDescriptorsFromTableStart = 0; r0[0].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;
        r0[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV; r0[1].NumDescriptors = 2; r0[1].OffsetInDescriptorsFromTableStart = 3; r0[1].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;
        r1[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER; r1[0].NumDescriptors = 2;
        prm[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; prm[0].DescriptorTable.NumDescriptorRanges = 2; prm[0].DescriptorTable.pDescriptorRanges = r0; prm[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        prm[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; prm[1].DescriptorTable.NumDescriptorRanges = 1; prm[1].DescriptorTable.pDescriptorRanges = r1; prm[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        vd.Version = D3D_ROOT_SIGNATURE_VERSION_1_1; vd.Desc_1_1.NumParameters = 2; vd.Desc_1_1.pParameters = prm;
        hr = ser ? ser(&vd, &blob, &err) : E_NOTIMPL;
        if (FAILED(hr)) { say("D3D12SerializeVersionedRootSignature 0x%08lx %s", (unsigned long)hr, err ? (char *)ID3D10Blob_GetBufferPointer(err) : ""); return 0; }
        hr = ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)&rootsig);
        say("  CreateRootSignature: 0x%08lx", (unsigned long)hr);
        if (FAILED(hr)) return 0;
    }
    return 1;
}

// ---- the tests -------------------------------------------------------------------------------
static int check(const int *expect, int n, const UINT32 *got, char *out, size_t outsz) {
    int i, ok = 1; size_t len = 0;
    for (i = 0; i < n; i++) {
        len += snprintf(out + len, outsz - len, "%s%u", i ? "," : "", got[i]);
        if (expect[i] >= 0 && (UINT32)expect[i] != got[i]) ok = 0;
    }
    return ok;
}

static void run_compute(const ComputeTest *t) {
    SIZE_T size; void *blob; D3D12_COMPUTE_PIPELINE_STATE_DESC pd; ID3D12PipelineState *pso = NULL; HRESULT hr; void *p; UINT32 got[16]; char s[256]; int ok;
    say("== %s: %s", t->name, t->what);
    blob = load_blob(t->name, &size); if (!blob) return;
    describe_blob(t->name, blob, size);
    if (!strcmp(t->name, "cs67_msaawrite") && !msaa_ok) { say("  SKIPPED: the writable multisampled texture could not be created"); free(blob); return; }
    memset(&pd, 0, sizeof pd); pd.pRootSignature = rootsig; pd.CS.pShaderBytecode = blob; pd.CS.BytecodeLength = size;
    hr = ID3D12Device_CreateComputePipelineState(dev, &pd, &IID_ID3D12PipelineState, (void **)&pso);
    say("  CreateComputePipelineState: 0x%08lx%s", (unsigned long)hr, SUCCEEDED(hr) ? "" : "  <-- REFUSED");
    if (FAILED(hr) || !pso) { free(blob); return; }
    if (FAILED(begin())) { say("  command list reset failed"); return; }
    barrier(uav_buf, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12GraphicsCommandList_CopyBufferRegion(list, uav_buf, 0, zero_upload, 0, 1024);
    barrier(uav_buf, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    { ID3D12DescriptorHeap *heaps[2] = { res_heap, samp_heap }; ID3D12GraphicsCommandList_SetDescriptorHeaps(list, 2, heaps); }
    ID3D12GraphicsCommandList_SetComputeRootSignature(list, rootsig);
    ID3D12GraphicsCommandList_SetComputeRootDescriptorTable(list, 0, gpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 0));
    ID3D12GraphicsCommandList_SetComputeRootDescriptorTable(list, 1, gpu_handle(samp_heap, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 0));
    ID3D12GraphicsCommandList_SetPipelineState(list, pso);
    ID3D12GraphicsCommandList_Dispatch(list, 1, 1, 1);
    barrier(uav_buf, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    ID3D12GraphicsCommandList_CopyBufferRegion(list, readback, 0, uav_buf, 0, 1024);
    barrier(uav_buf, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    hr = submit(t->name);
    if (SUCCEEDED(hr) && SUCCEEDED(ID3D12Resource_Map(readback, 0, NULL, &p))) {
        memcpy(got, p, sizeof got); ID3D12Resource_Unmap(readback, 0, NULL);
        ok = check(t->expect, t->n, got, s, sizeof s);
        say("  dispatch ran, output %s -> %s", s, ok ? "CORRECT" : "WRONG (0xeeeeeeee = untouched)");
    }
    ID3D12PipelineState_Release(pso); free(blob);
}

static void run_graphics(const GraphicsTest *t) {
    SIZE_T vsz, psz; void *vs, *ps; D3D12_GRAPHICS_PIPELINE_STATE_DESC pd; ID3D12PipelineState *pso = NULL; HRESULT hr; void *p; int i;
    D3D12_VIEWPORT vp = { 0, 0, 4, 4, 0, 1 }; D3D12_RECT sc = { 0, 0, 4, 4 }; FLOAT clear[4] = { 0, 0, 0, 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = cpu_handle(rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 0);
    D3D12_TEXTURE_COPY_LOCATION dst, src; D3D12_RESOURCE_DESC d; D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT rows; UINT64 rowbytes, total;
    say("== %s + %s: %s", t->vs, t->ps, t->what);
    vs = load_blob(t->vs, &vsz); ps = load_blob(t->ps, &psz); if (!vs || !ps) return;
    describe_blob(t->vs, vs, vsz); describe_blob(t->ps, ps, psz);
    memset(&pd, 0, sizeof pd); pd.pRootSignature = rootsig;
    pd.VS.pShaderBytecode = vs; pd.VS.BytecodeLength = vsz; pd.PS.pShaderBytecode = ps; pd.PS.BytecodeLength = psz;
    for (i = 0; i < 8; i++) pd.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = 0xffffffff; pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE; pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE; pd.NumRenderTargets = 1; pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; pd.SampleDesc.Count = 1;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pd, &IID_ID3D12PipelineState, (void **)&pso);
    say("  CreateGraphicsPipelineState: 0x%08lx%s", (unsigned long)hr, SUCCEEDED(hr) ? "" : "  <-- REFUSED");
    if (FAILED(hr) || !pso) { free(vs); free(ps); return; }
    if (FAILED(begin())) { say("  command list reset failed"); return; }
    { ID3D12DescriptorHeap *heaps[2] = { res_heap, samp_heap }; ID3D12GraphicsCommandList_SetDescriptorHeaps(list, 2, heaps); }
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rootsig);
    ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(list, 0, gpu_handle(res_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 0));
    ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(list, 1, gpu_handle(samp_heap, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 0));
    ID3D12GraphicsCommandList_SetPipelineState(list, pso);
    ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp); ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &sc);
    ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, clear, 0, NULL);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
    barrier(rt_tex, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    d = ID3D12Resource_GetDesc(rt_tex); ID3D12Device_GetCopyableFootprints(dev, &d, 0, 1, 0, &fp, &rows, &rowbytes, &total);
    memset(&dst, 0, sizeof dst); dst.pResource = rt_readback; dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = fp;
    memset(&src, 0, sizeof src); src.pResource = rt_tex; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    barrier(rt_tex, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET);
    hr = submit(t->ps);
    if (SUCCEEDED(hr) && SUCCEEDED(ID3D12Resource_Map(rt_readback, 0, NULL, &p))) {
        const unsigned char *b = (const unsigned char *)p + fp.Offset; const unsigned char *p00 = b, *p33 = b + 3 * fp.Footprint.RowPitch + 3 * 4;
        int ok = 1;
        for (i = 0; i < 4; i++) { if (t->p00[i] >= 0 && p00[i] != t->p00[i]) ok = 0; if (t->p33[i] >= 0 && p33[i] != t->p33[i]) ok = 0; }
        say("  draw ran, pixel (0,0) %u,%u,%u,%u pixel (3,3) %u,%u,%u,%u -> %s", p00[0], p00[1], p00[2], p00[3], p33[0], p33[1], p33[2], p33[3], ok ? "CORRECT" : "WRONG");
        ID3D12Resource_Unmap(rt_readback, 0, NULL);
    }
    ID3D12PipelineState_Release(pso); free(vs); free(ps);
}

int main(int argc, char **argv) {
    HMODULE m; typedef HRESULT (WINAPI *create_t)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **); create_t create; HRESULT hr; char path[MAX_PATH]; unsigned i;
    if (argc < 2) { say("usage: smprobe.exe <windows path of the dxil folder>"); return 1; }
    strncpy(dxil_dir, argv[1], sizeof dxil_dir - 1);
    say("smprobe: shader model 6.7 on this Direct3D 12 runtime, blobs from %s", dxil_dir);
    m = LoadLibraryA("d3d12.dll"); if (!m) { say("LoadLibrary(d3d12.dll) failed, error %lu", GetLastError()); return 1; }
    GetModuleFileNameA(m, path, sizeof path); say("d3d12.dll: %s", path);
    if (GetModuleHandleA("apd12.dll")) { GetModuleFileNameA(GetModuleHandleA("apd12.dll"), path, sizeof path); say("shim in front, real: %s", path); }
    create = (create_t)GetProcAddress(m, "D3D12CreateDevice");
    hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    say("D3D12CreateDevice(11_0): 0x%08lx", (unsigned long)hr); if (FAILED(hr)) return 2;
    {   // what the runtime says before anything is compiled
        static const int SMS[] = { 0x60, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a };
        D3D12_FEATURE_DATA_D3D12_OPTIONS14 o14; D3D12_FEATURE_DATA_D3D12_OPTIONS1 o1; D3D12_FEATURE_DATA_D3D12_OPTIONS o0;
        IDXGIFactory4 *fx = NULL; typedef HRESULT (WINAPI *cf2_t)(UINT, REFIID, void **); HMODULE dxgi = LoadLibraryA("dxgi.dll");
        cf2_t cf2 = dxgi ? (cf2_t)GetProcAddress(dxgi, "CreateDXGIFactory2") : NULL;
        for (i = 0; i < sizeof SMS / sizeof *SMS; i++) {
            D3D12_FEATURE_DATA_SHADER_MODEL sm = { (D3D_SHADER_MODEL)SMS[i] };
            hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof sm);
            say("CheckFeatureSupport(SHADER_MODEL ask 0x%x): 0x%08lx -> 0x%x", SMS[i], (unsigned long)hr, sm.HighestShaderModel);
        }
        memset(&o0, 0, sizeof o0); hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o0, sizeof o0);
        say("OPTIONS: 0x%08lx, ResourceBindingTier %d, TiledResourcesTier %d", (unsigned long)hr, o0.ResourceBindingTier, o0.TiledResourcesTier);
        memset(&o1, 0, sizeof o1); hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS1, &o1, sizeof o1);
        say("OPTIONS1: 0x%08lx, WaveOps %d, lanes %u..%u, Int64ShaderOps %d", (unsigned long)hr, o1.WaveOps, o1.WaveLaneCountMin, o1.WaveLaneCountMax, o1.Int64ShaderOps);
        memset(&o14, 0, sizeof o14); hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS14, &o14, sizeof o14);
        say("OPTIONS14: 0x%08lx, AdvancedTextureOpsSupported %d, WriteableMSAATexturesSupported %d, IndependentFrontAndBackStencilRefMaskSupported %d",
            (unsigned long)hr, o14.AdvancedTextureOpsSupported, o14.WriteableMSAATexturesSupported, o14.IndependentFrontAndBackStencilRefMaskSupported);
        if (cf2 && SUCCEEDED(cf2(0, &IID_IDXGIFactory4, (void **)&fx)) && fx) {
            IDXGIAdapter1 *ad = NULL; DXGI_ADAPTER_DESC1 ds;
            if (IDXGIFactory4_EnumAdapters1(fx, 0, &ad) == S_OK) { memset(&ds, 0, sizeof ds); IDXGIAdapter1_GetDesc1(ad, &ds); say("adapter 0: %ls, vendor 0x%04x, device 0x%04x", ds.Description, ds.VendorId, ds.DeviceId); IDXGIAdapter1_Release(ad); }
            IDXGIFactory4_Release(fx);
        }
    }
    say("== setup");
    if (!setup()) { say("setup failed"); return 3; }
    for (i = 0; i < sizeof COMPUTE / sizeof *COMPUTE; i++) run_compute(&COMPUTE[i]);
    for (i = 0; i < sizeof GRAPHICS / sizeof *GRAPHICS; i++) run_graphics(&GRAPHICS[i]);
    say("smprobe: done (device removed reason 0x%08lx)", (unsigned long)ID3D12Device_GetDeviceRemovedReason(dev));
    return 0;
}
