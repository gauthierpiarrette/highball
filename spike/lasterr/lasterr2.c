// Walk the last-error slot across crossings: set, syscall, read, then a failing API.
#include <windows.h>
#include <stdio.h>
static void show(const char *tag) {
    DWORD api = GetLastError(); DWORD teb = *(DWORD *)((char *)NtCurrentTeb() + 0x68); DWORD gs = __readgsdword(0x68);
    printf("%-34s GetLastError=%lu TEB=%lu gs:0x68=%lu (0x%lx)\n", tag, api, teb, gs, gs);
}
int main(void) {
    SetLastError(7); show("after SetLastError(7)");
    Sleep(0); show("after Sleep(0) [syscall]");
    HANDLE h = CreateFileW(L"C:\\windows\\system32\\kernel32.dll", GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    show("after CreateFileW ok");
    CloseHandle(h); show("after CloseHandle");
    SetLastError(0); DeleteFileW(L"C:\\users\\public\\nope-12345.tmp"); show("after DeleteFileW missing");
    SetLastError(0); GetFileAttributesW(L"C:\\users\\public\\nope-12345.tmp"); show("after GetFileAttributesW missing");
    return 0;
}
