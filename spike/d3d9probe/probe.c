// d3d9probe: create a Direct3D 9 device on a hidden window, clear and present a few frames,
// print what happened. Exit 0 when the device came up and presented, 1 otherwise. Built for
// both halves with mingw so a d3d9 layer can be judged without a game or a screen.
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 30;
    HWND hwnd = CreateWindowExA(0, "STATIC", "d3d9probe", WS_OVERLAPPEDWINDOW, 0, 0, 640, 480, NULL, NULL, GetModuleHandle(NULL), NULL);
    if (!hwnd) { printf("no window\n"); return 1; }
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("Direct3DCreate9 failed\n"); return 1; }
    UINT n = IDirect3D9_GetAdapterCount(d3d);
    printf("adapters: %u\n", n);
    for (UINT i = 0; i < n; i++) {
        D3DADAPTER_IDENTIFIER9 id;
        if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, i, 0, &id)))
            printf("adapter %u: %s (%s) vendor %04x device %04x\n", i, id.Description, id.Driver, id.VendorId, id.DeviceId);
    }
    D3DCAPS9 caps;
    if (SUCCEEDED(IDirect3D9_GetDeviceCaps(d3d, 0, D3DDEVTYPE_HAL, &caps)))
        printf("caps: vs %x ps %x maxtex %ux%u\n", (unsigned)caps.VertexShaderVersion, (unsigned)caps.PixelShaderVersion, (unsigned)caps.MaxTextureWidth, (unsigned)caps.MaxTextureHeight);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.hDeviceWindow = hwnd;
    pp.BackBufferFormat = D3DFMT_UNKNOWN; pp.EnableAutoDepthStencil = TRUE; pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr) || !dev) { printf("CreateDevice failed: 0x%08lx\n", hr); return 1; }
    printf("device created\n");
    int ok = 0;
    for (int f = 0; f < frames; f++) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, D3DCOLOR_XRGB(f * 8 & 255, 64, 128), 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev); IDirect3DDevice9_EndScene(dev);
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { printf("Present failed at frame %d: 0x%08lx\n", f, hr); break; }
        ok++;
    }
    printf("presented %d/%d frames\n", ok, frames);
    IDirect3DDevice9_Release(dev); IDirect3D9_Release(d3d);
    return ok == frames ? 0 : 1;
}
