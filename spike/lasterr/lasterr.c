// Does GetLastError() hold ERROR_FILE_NOT_FOUND after DeleteFileW on a missing file, or garbage?
// Unity's Mono threw IOException "Unknown error (0xd6305a70)" from File.Delete on Wine/macOS
// (The Last Flame, 2026-09-20). Reads the value three ways: the API, the TEB via NtCurrentTeb(),
// and %gs:0x68 directly (what code compiled against the Windows layout may do).
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
    return 0;
}
