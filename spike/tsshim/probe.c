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

    ID3D12Device *dev = NULL;
    HRESULT hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    say("D3D12CreateDevice: 0x%08lx", (unsigned long)hr);
    if (FAILED(hr) || !dev) return 3;

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
    say("dx12probe: done");
    return 0;
}
