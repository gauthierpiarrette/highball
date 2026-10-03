// Does GetLastError() hold ERROR_FILE_NOT_FOUND after DeleteFileW on a missing file, or garbage?
// Unity's Mono threw IOException "Unknown error (0xd6305a70)" from File.Delete on Wine/macOS
// (The Last Flame, 2026-09-20). Reads the value three ways: the API, the TEB via NtCurrentTeb(),
// and %gs:0x68 directly (what code compiled against the Windows layout may do).
//
// Then the same after a display call, a window and a message to it. Each of those runs a
// user-mode callback (the driver load, the window procedure), and engine patch 0011 as shipped
// in r11 to r14 wrote the error back to the TEB a second time on that callback's return, so
// GetLastError() came back as a heap pointer afterwards. The Rockstar Games Launcher installer
// reads it right after it measures the display and refused to install (highball-db#272,
// 2026-10-02). Patch 0016 (r15) removed the second write. A value above 0xFFFF is never a
// Windows error code, so that is what the engine probe checks.
#include <windows.h>
#include <stdio.h>
int main(void) {
    SetLastError(0);
    BOOL ok = DeleteFileW(L"C:\\users\\public\\does-not-exist-12345.tmp");
    DWORD api = GetLastError();
    DWORD teb = *(DWORD *)((char *)NtCurrentTeb() + 0x68);
    DWORD gs = __readgsdword(0x68);
    printf("DeleteFileW ok=%d GetLastError=%lu (0x%lx) TEB->LastErrorValue=%lu %%gs:0x68=%lu (0x%lx)\n", ok, api, api, teb, gs, gs);
    SetLastError(1234);
    printf("after SetLastError(1234): GetLastError=%lu %%gs:0x68=%lu (0x%lx) TEB self=%p\n", GetLastError(), __readgsdword(0x68), __readgsdword(0x68), (void*)NtCurrentTeb());
    SetLastError(21);
    GetSystemMetrics(SM_CXSCREEN);
    api = GetLastError();
    printf("after GetSystemMetrics: GetLastError=%lu (0x%lx)\n", api, api);
    SetLastError(35);
    HWND w = CreateWindowExW(0, L"STATIC", L"lasterr", WS_POPUP, 0, 0, 8, 8, NULL, NULL, GetModuleHandleW(NULL), NULL);
    api = GetLastError();
    printf("after CreateWindowExW: GetLastError=%lu (0x%lx)\n", api, api);
    SetLastError(55);
    SendMessageW(w, WM_NULL, 0, 0);
    api = GetLastError();
    printf("after SendMessageW: GetLastError=%lu (0x%lx)\n", api, api);
    DestroyWindow(w);
    return 0;
}
