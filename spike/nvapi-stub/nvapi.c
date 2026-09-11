/* Minimal NVAPI stub for a 32-bit Direct3D 9 game that refuses to run without NVIDIA's
 * driver library when the adapter says NVIDIA. nvapi_QueryInterface hands out
 * NvAPI_Initialize (OK), NvAPI_Unload (OK), NvAPI_GetErrorMessage and
 * NvAPI_GetInterfaceVersionString (fixed strings); everything else answers
 * NVAPI_NO_IMPLEMENTATION so a caller that probes optional features moves on. */
#include <windows.h>

typedef int NvAPI_Status;
#define NVAPI_OK 0
#define NVAPI_NO_IMPLEMENTATION (-3)

static NvAPI_Status __cdecl stub_Initialize(void) { return NVAPI_OK; }
static NvAPI_Status __cdecl stub_Unload(void) { return NVAPI_OK; }
static NvAPI_Status __cdecl stub_NoImpl(void) { return NVAPI_NO_IMPLEMENTATION; }
static void copy64(char *dst, const char *src) { int i = 0; if (!dst) return; while (i < 63 && src[i]) { dst[i] = src[i]; i++; } dst[i] = 0; }
static NvAPI_Status __cdecl stub_GetErrorMessage(NvAPI_Status s, char msg[64]) {
    copy64(msg, s == NVAPI_OK ? "NVAPI_OK" : "NVAPI_NO_IMPLEMENTATION");
    return NVAPI_OK;
}
static NvAPI_Status __cdecl stub_GetInterfaceVersionString(char ver[64]) {
    copy64(ver, "HIGHBALL NVAPI stub R470");
    return NVAPI_OK;
}

__declspec(dllexport) void * __cdecl nvapi_QueryInterface(unsigned int id) {
    switch (id) {
    case 0x0150E828: return (void *)stub_Initialize;              /* NvAPI_Initialize */
    case 0xD22BDD7E: return (void *)stub_Unload;                  /* NvAPI_Unload */
    case 0x6C2D048C: return (void *)stub_GetErrorMessage;         /* NvAPI_GetErrorMessage */
    case 0x01053FA5: return (void *)stub_GetInterfaceVersionString;
    default:         return (void *)stub_NoImpl;
    }
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) { (void)h; (void)r; return TRUE; }
