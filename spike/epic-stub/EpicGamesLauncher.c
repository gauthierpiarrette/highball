/* EpicGamesLauncher.exe stand-in for Rockstar games bought on Epic (highball#93).
 *
 * The Rockstar Games Launcher accepts an Epic entitlement only while a process named
 * EpicGamesLauncher.exe exists. Highball starts this program under that name from the game's
 * folder with the real executable and Legendary's launch arguments after it; it starts that
 * command in the same folder and stays alive until the game exits, which is all the launcher
 * checks. Same idea as Heroic's stand-in (BananaWorks07/heroic-epic-integration, MIT), written
 * from scratch here so the source ships with Highball and builds with mingw at app build time.
 *
 * Usage: EpicGamesLauncher.exe <program.exe> [arguments...]
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv)
{
    if (argc < 2) { fwprintf(stderr, L"usage: EpicGamesLauncher.exe <program.exe> [arguments...]\n"); return 2; }

    /* Run from the folder this stand-in lives in, which is the game folder. */
    wchar_t dir[MAX_PATH];
    GetModuleFileNameW(NULL, dir, MAX_PATH);
    wchar_t *slash = wcsrchr(dir, L'\\');
    if (slash) *slash = 0;

    /* Command line: "<program>" then the arguments, each quoted if it has a space. */
    size_t len = 4;
    for (int i = 1; i < argc; i++) len += wcslen(argv[i]) + 4;
    wchar_t *cmd = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, len * sizeof(wchar_t));
    if (!cmd) return 3;
    cmd[0] = 0;
    for (int i = 1; i < argc; i++) {
        if (i > 1) wcscat(cmd, L" ");
        int quote = wcschr(argv[i], L' ') != NULL;
        if (quote) wcscat(cmd, L"\"");
        wcscat(cmd, argv[i]);
        if (quote) wcscat(cmd, L"\"");
    }

    /* A leftover Steam id would make the game look for Steam instead of Epic. */
    SetEnvironmentVariableW(L"SteamAppId", NULL);
    SetEnvironmentVariableW(L"SteamGameId", NULL);

    STARTUPINFOW si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si); ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi)) {
        fwprintf(stderr, L"EpicGamesLauncher stand-in: could not start %ls (error %lu)\n", argv[1], GetLastError());
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
}
