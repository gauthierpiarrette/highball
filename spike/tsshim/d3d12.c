// tsshim: a d3d12.dll that sits in front of D3DMetal's and serves DirectX 12 timestamp queries.
//
// D3DMetal 3.0 has no timestamp queries: CreateQueryHeap hands back a heap, then EndQuery and
// ResolveQueryData for query type 2 log a refusal and do nothing, so a game that times its
// frames reads garbage and crashes (Guardians of the Galaxy, highball #63). This proxy loads
// the real D3DMetal d3d12.dll (HB_D3D12_REAL, a Windows path), forwards everything, and after
// D3D12CreateDevice patches four vtable slots: the device's CreateQueryHeap answers timestamp
// heaps itself, the command list's EndQuery stamps the CPU clock into that heap, its
// ResolveQueryData copies the stamps into the destination buffer through an upload ring, and
// the queue reports the CPU clock's frequency. Everything else is D3DMetal untouched.
//
// Build: x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o d3d12.dll d3d12.c d3d12.def
// then stamp the "Wine builtin DLL" marker so WINEDLLPATH_PREPEND picks it up.
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HMODULE real_dll;
static HINSTANCE self;
static int dbg, idle;
static UINT64 qpc_freq;
#define LOG(...) do { if (dbg) { fprintf(stderr, "tsshim: " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } } while (0)

// Wine resolves builtin modules by base name, so a second "d3d12.dll" at another path comes back as
// this shim. The real one therefore lives beside the shim as d3d12_d3dmetal.dll with its Mach-O half
// as x86_64-unix/d3d12_d3dmetal.so (Highball lays both out from the licensed D3DMetal overlay).
// HB_D3D12_REAL, a Windows path or module name, overrides that for experiments.
static HMODULE load_real(void)
{
    WCHAR path[1024];
    DWORD n;
    if (real_dll) return real_dll;
    n = GetEnvironmentVariableW(L"HB_D3D12_REAL", path, 1024);
    if (n && n < 1024) real_dll = LoadLibraryW(path);
    else real_dll = LoadLibraryW(L"d3d12_d3dmetal.dll");
    if (real_dll == self) { fprintf(stderr, "tsshim: the real d3d12.dll resolved to the shim itself\n"); real_dll = NULL; }
    if (!real_dll) fprintf(stderr, "tsshim: cannot load the real D3DMetal d3d12.dll (%ls, error %lu)\n", n ? path : L"d3d12_d3dmetal.dll", GetLastError());
    return real_dll;
}

// Forwarded exports: a jump through a pointer resolved at load, so no signature is guessed.
#define FORWARD(name) \
    static void *p_##name __attribute__((used)); \
    __asm__(".text\n.globl " #name "\n" #name ":\n\tjmp *p_" #name "(%rip)\n");
FORWARD(D3D12CoreCreateLayeredDevice)
FORWARD(D3D12CoreGetLayeredDeviceSize)
FORWARD(D3D12CoreRegisterLayers)
FORWARD(D3D12CreateRootSignatureDeserializer)
FORWARD(D3D12CreateVersionedRootSignatureDeserializer)
FORWARD(D3D12EnableExperimentalFeatures)
FORWARD(D3D12GetDebugInterface)
FORWARD(D3D12SerializeRootSignature)
FORWARD(D3D12SerializeVersionedRootSignature)
FORWARD(GetBehaviorValue)
#define RESOLVE(name) do { p_##name = (void *)GetProcAddress(real_dll, #name); if (!p_##name) LOG("real d3d12.dll lacks %s", #name); } while (0)

// ---- the fake timestamp query heap -------------------------------------------------------

typedef struct FakeHeap {
    const ID3D12QueryHeapVtbl *lpVtbl;
    LONG ref;
    UINT count;
    UINT64 *values;
    ID3D12Device *device;
} FakeHeap;

static const ID3D12QueryHeapVtbl fake_heap_vtbl;
static int is_fake(ID3D12QueryHeap *h) { return h && h->lpVtbl == &fake_heap_vtbl; }

static HRESULT STDMETHODCALLTYPE fh_QueryInterface(ID3D12QueryHeap *iface, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_ID3D12Object) || IsEqualGUID(riid, &IID_ID3D12DeviceChild)
        || IsEqualGUID(riid, &IID_ID3D12Pageable) || IsEqualGUID(riid, &IID_ID3D12QueryHeap)) {
        InterlockedIncrement(&((FakeHeap *)iface)->ref); *out = iface; return S_OK;
    }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE fh_AddRef(ID3D12QueryHeap *iface) { return InterlockedIncrement(&((FakeHeap *)iface)->ref); }
static ULONG STDMETHODCALLTYPE fh_Release(ID3D12QueryHeap *iface)
{
    FakeHeap *h = (FakeHeap *)iface; ULONG r = InterlockedDecrement(&h->ref);
    if (!r) { h->device->lpVtbl->Release(h->device); free(h->values); free(h); }
    return r;
}
static HRESULT STDMETHODCALLTYPE fh_GetPrivateData(ID3D12QueryHeap *iface, REFGUID guid, UINT *size, void *data) { if (size) *size = 0; return (HRESULT)0x887A0002L; /* DXGI_ERROR_NOT_FOUND */ }
static HRESULT STDMETHODCALLTYPE fh_SetPrivateData(ID3D12QueryHeap *iface, REFGUID guid, UINT size, const void *data) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_SetPrivateDataInterface(ID3D12QueryHeap *iface, REFGUID guid, const IUnknown *data) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_SetName(ID3D12QueryHeap *iface, LPCWSTR name) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_GetDevice(ID3D12QueryHeap *iface, REFIID riid, void **out)
{
    FakeHeap *h = (FakeHeap *)iface; return h->device->lpVtbl->QueryInterface(h->device, riid, out);
}
static const ID3D12QueryHeapVtbl fake_heap_vtbl = {
    fh_QueryInterface, fh_AddRef, fh_Release, fh_GetPrivateData, fh_SetPrivateData, fh_SetPrivateDataInterface, fh_SetName, fh_GetDevice
};

// ---- the upload ring the stamps travel through ---------------------------------------------

#define RING_BYTES (8u << 20)
typedef struct Ring { ID3D12Device *device; ID3D12Resource *buffer; UINT8 *cpu; volatile LONG64 cursor; } Ring;
static Ring rings[4];
static CRITICAL_SECTION ring_lock;

static Ring *ring_for(ID3D12Device *dev)
{
    Ring *r = NULL; int i;
    EnterCriticalSection(&ring_lock);
    for (i = 0; i < 4 && !r; i++) if (rings[i].device == dev) r = &rings[i];
    for (i = 0; i < 4 && !r; i++) if (!rings[i].device) {
        D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
        D3D12_RESOURCE_DESC rd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, RING_BYTES, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE };
        ID3D12Resource *buf = NULL; void *cpu = NULL;
        if (SUCCEEDED(dev->lpVtbl->CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&buf))
            && SUCCEEDED(buf->lpVtbl->Map(buf, 0, NULL, &cpu))) {
            rings[i].device = dev; dev->lpVtbl->AddRef(dev);
            rings[i].buffer = buf; rings[i].cpu = cpu; rings[i].cursor = 0; r = &rings[i];
            LOG("upload ring of %u bytes created", RING_BYTES);
        } else { if (buf) buf->lpVtbl->Release(buf); LOG("upload ring creation failed"); }
        break;
    }
    LeaveCriticalSection(&ring_lock);
    return r;
}

static UINT64 now_ticks(void) { LARGE_INTEGER c; QueryPerformanceCounter(&c); return (UINT64)c.QuadPart; }

// ---- the hooks -----------------------------------------------------------------------------

typedef HRESULT (STDMETHODCALLTYPE *PFN_CreateQueryHeap)(ID3D12Device *, const D3D12_QUERY_HEAP_DESC *, REFIID, void **);
typedef void (STDMETHODCALLTYPE *PFN_Query)(ID3D12GraphicsCommandList *, ID3D12QueryHeap *, D3D12_QUERY_TYPE, UINT);
typedef void (STDMETHODCALLTYPE *PFN_ResolveQueryData)(ID3D12GraphicsCommandList *, ID3D12QueryHeap *, D3D12_QUERY_TYPE, UINT, UINT, ID3D12Resource *, UINT64);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetTimestampFrequency)(ID3D12CommandQueue *, UINT64 *);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetClockCalibration)(ID3D12CommandQueue *, UINT64 *, UINT64 *);
static PFN_CreateQueryHeap real_CreateQueryHeap;
static PFN_Query real_EndQuery, real_BeginQuery;
static PFN_ResolveQueryData real_ResolveQueryData;
static PFN_GetTimestampFrequency real_GetTimestampFrequency;
static PFN_GetClockCalibration real_GetClockCalibration;

static HRESULT STDMETHODCALLTYPE hook_CreateQueryHeap(ID3D12Device *dev, const D3D12_QUERY_HEAP_DESC *desc, REFIID riid, void **out)
{
    FakeHeap *h; HRESULT hr;
    if (!desc || (desc->Type != D3D12_QUERY_HEAP_TYPE_TIMESTAMP && desc->Type != D3D12_QUERY_HEAP_TYPE_COPY_QUEUE_TIMESTAMP))
        return real_CreateQueryHeap(dev, desc, riid, out);
    if (!out) return S_FALSE;
    h = calloc(1, sizeof *h); if (!h) return E_OUTOFMEMORY;
    h->lpVtbl = &fake_heap_vtbl; h->ref = 1; h->count = desc->Count;
    h->values = calloc(desc->Count ? desc->Count : 1, sizeof(UINT64));
    h->device = dev; dev->lpVtbl->AddRef(dev);
    hr = fh_QueryInterface((ID3D12QueryHeap *)h, riid, out);
    fh_Release((ID3D12QueryHeap *)h);
    LOG("timestamp query heap of %u entries served by the shim (hr 0x%08lx)", desc->Count, (unsigned long)hr);
    return hr;
}

static void STDMETHODCALLTYPE hook_EndQuery(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, UINT index)
{
    FakeHeap *h;
    if (!is_fake(heap)) { real_EndQuery(list, heap, type, index); return; }
    h = (FakeHeap *)heap; if (index < h->count) h->values[index] = now_ticks();
}

static void STDMETHODCALLTYPE hook_BeginQuery(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, UINT index)
{
    if (!is_fake(heap)) real_BeginQuery(list, heap, type, index);
}

static void STDMETHODCALLTYPE hook_ResolveQueryData(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type,
                                                    UINT start, UINT count, ID3D12Resource *dst, UINT64 offset)
{
    FakeHeap *h; Ring *r; UINT64 bytes, off; LONG64 pos; int tries;
    if (!is_fake(heap)) { real_ResolveQueryData(list, heap, type, start, count, dst, offset); return; }
    h = (FakeHeap *)heap; r = ring_for(h->device);
    if (!r || !dst || !count || start >= h->count) return;
    if (start + count > h->count) count = h->count - start;
    bytes = (UINT64)count * 8; if (bytes > RING_BYTES / 2) return;
    for (tries = 0; tries < 2; tries++) {
        pos = InterlockedExchangeAdd64(&r->cursor, (LONG64)bytes); off = (UINT64)pos % RING_BYTES;
        if (off + bytes <= RING_BYTES) break;
        InterlockedExchangeAdd64(&r->cursor, (LONG64)(RING_BYTES - off));   // skip the tail, start over
    }
    if (tries == 2) return;
    memcpy(r->cpu + off, h->values + start, (size_t)bytes);
    list->lpVtbl->CopyBufferRegion(list, dst, offset, r->buffer, off, bytes);
}

static HRESULT STDMETHODCALLTYPE hook_GetTimestampFrequency(ID3D12CommandQueue *q, UINT64 *f)
{
    if (!f) return E_INVALIDARG;
    *f = qpc_freq; return S_OK;
}
static HRESULT STDMETHODCALLTYPE hook_GetClockCalibration(ID3D12CommandQueue *q, UINT64 *gpu, UINT64 *cpu)
{
    UINT64 t = now_ticks(); if (gpu) *gpu = t; if (cpu) *cpu = t; return S_OK;
}

// ---- patching ------------------------------------------------------------------------------

static void patch_slot(void **slot, void *hook, void **saved)
{
    DWORD old;
    if (*slot == hook) return;
    // D3DMetal's vtables live in its framework's __DATA segment on the Mach-O side: writable, but
    // outside Wine's view of memory, so VirtualProtect refuses the address. Try it for the PE case,
    // then write regardless (verified on D3DMetal 3.0 with Wine 10 and 11, 2026-09-07).
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) old = 0;
    if (!*saved) *saved = *slot;
    *slot = hook;
    if (old) VirtualProtect(slot, sizeof(void *), old, &old);
}

static void patch_device_vtbl(void *iface)
{
    ID3D12DeviceVtbl *vt = *(ID3D12DeviceVtbl **)iface;
    patch_slot((void **)&vt->CreateQueryHeap, (void *)hook_CreateQueryHeap, (void **)&real_CreateQueryHeap);
}
static void patch_list_vtbl(void *iface)
{
    ID3D12GraphicsCommandListVtbl *vt = *(ID3D12GraphicsCommandListVtbl **)iface;
    patch_slot((void **)&vt->EndQuery, (void *)hook_EndQuery, (void **)&real_EndQuery);
    patch_slot((void **)&vt->BeginQuery, (void *)hook_BeginQuery, (void **)&real_BeginQuery);
    patch_slot((void **)&vt->ResolveQueryData, (void *)hook_ResolveQueryData, (void **)&real_ResolveQueryData);
}
static void patch_queue_vtbl(void *iface)
{
    ID3D12CommandQueueVtbl *vt = *(ID3D12CommandQueueVtbl **)iface;
    patch_slot((void **)&vt->GetTimestampFrequency, (void *)hook_GetTimestampFrequency, (void **)&real_GetTimestampFrequency);
    patch_slot((void **)&vt->GetClockCalibration, (void *)hook_GetClockCalibration, (void **)&real_GetClockCalibration);
}

// Every interface generation may carry its own vtable copy, so patch each one the object answers to.
static void patch_all(IUnknown *obj, const IID *const *ids, int n, void (*patch)(void *))
{
    int i; void *p;
    patch(obj);
    for (i = 0; i < n; i++) {
        if (FAILED(obj->lpVtbl->QueryInterface(obj, ids[i], &p)) || !p) continue;
        patch(p); ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
    }
}

static void patch_device(ID3D12Device *dev)
{
    static const IID *const dev_ids[] = {
        &IID_ID3D12Device1, &IID_ID3D12Device2, &IID_ID3D12Device3, &IID_ID3D12Device4, &IID_ID3D12Device5,
#ifdef __ID3D12Device6_INTERFACE_DEFINED__
        &IID_ID3D12Device6,
#endif
#ifdef __ID3D12Device7_INTERFACE_DEFINED__
        &IID_ID3D12Device7,
#endif
#ifdef __ID3D12Device8_INTERFACE_DEFINED__
        &IID_ID3D12Device8,
#endif
#ifdef __ID3D12Device9_INTERFACE_DEFINED__
        &IID_ID3D12Device9,
#endif
#ifdef __ID3D12Device10_INTERFACE_DEFINED__
        &IID_ID3D12Device10,
#endif
    };
    static const IID *const list_ids[] = {
        &IID_ID3D12GraphicsCommandList1, &IID_ID3D12GraphicsCommandList2, &IID_ID3D12GraphicsCommandList3,
        &IID_ID3D12GraphicsCommandList4, &IID_ID3D12GraphicsCommandList5, &IID_ID3D12GraphicsCommandList6,
#ifdef __ID3D12GraphicsCommandList7_INTERFACE_DEFINED__
        &IID_ID3D12GraphicsCommandList7,
#endif
    };
    static const D3D12_COMMAND_LIST_TYPE types[] = { D3D12_COMMAND_LIST_TYPE_DIRECT, D3D12_COMMAND_LIST_TYPE_COMPUTE, D3D12_COMMAND_LIST_TYPE_COPY };
    int t;
    patch_all((IUnknown *)dev, dev_ids, sizeof dev_ids / sizeof *dev_ids, patch_device_vtbl);
    for (t = 0; t < 3; t++) {
        ID3D12CommandAllocator *alloc = NULL; ID3D12GraphicsCommandList *list = NULL; ID3D12CommandQueue *queue = NULL;
        D3D12_COMMAND_QUEUE_DESC qd = { types[t], 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
        if (SUCCEEDED(dev->lpVtbl->CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue)) && queue) {
            patch_queue_vtbl(queue); queue->lpVtbl->Release(queue);
        }
        if (FAILED(dev->lpVtbl->CreateCommandAllocator(dev, types[t], &IID_ID3D12CommandAllocator, (void **)&alloc)) || !alloc) continue;
        if (SUCCEEDED(dev->lpVtbl->CreateCommandList(dev, 0, types[t], alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list)) && list) {
            patch_all((IUnknown *)list, list_ids, sizeof list_ids / sizeof *list_ids, patch_list_vtbl);
            list->lpVtbl->Close(list); list->lpVtbl->Release(list);
        }
        alloc->lpVtbl->Release(alloc);
    }
    LOG("device %p patched (timestamp frequency %llu Hz)", (void *)dev, (unsigned long long)qpc_freq);
}

// ---- exports -------------------------------------------------------------------------------

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **out)
{
    typedef HRESULT (WINAPI *PFN)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    PFN fn = real_dll ? (PFN)GetProcAddress(real_dll, "D3D12CreateDevice") : NULL;
    HRESULT hr;
    if (!fn) return E_FAIL;
    hr = fn(adapter, level, riid, out);
    if (SUCCEEDED(hr) && out && *out && !idle) {
        ID3D12Device *dev = NULL; IUnknown *u = (IUnknown *)*out;
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device, (void **)&dev)) && dev) { patch_device(dev); dev->lpVtbl->Release(dev); }
    }
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        LARGE_INTEGER f;
        self = inst;
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&ring_lock);
        QueryPerformanceFrequency(&f); qpc_freq = (UINT64)f.QuadPart;
        dbg = GetEnvironmentVariableA("HB_TSSHIM_DEBUG", NULL, 0) > 0;
        { char v[8]; idle = GetEnvironmentVariableA("HB_D3D12_TSSHIM", v, sizeof v) == 1 && v[0] == '0'; }   // kill switch
        if (!load_real()) return FALSE;
        RESOLVE(D3D12CoreCreateLayeredDevice); RESOLVE(D3D12CoreGetLayeredDeviceSize); RESOLVE(D3D12CoreRegisterLayers);
        RESOLVE(D3D12CreateRootSignatureDeserializer); RESOLVE(D3D12CreateVersionedRootSignatureDeserializer);
        RESOLVE(D3D12EnableExperimentalFeatures); RESOLVE(D3D12GetDebugInterface); RESOLVE(D3D12SerializeRootSignature);
        RESOLVE(D3D12SerializeVersionedRootSignature); RESOLVE(GetBehaviorValue);
        LOG("loaded in front of the real d3d12.dll");
    }
    return TRUE;
}
