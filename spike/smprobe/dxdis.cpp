// dxdis: disassemble every .dxil in a folder with dxcompiler.dll in ONE process and print, per shader, how many
// times the four DXIL operations D3DMetal's converter refuses appear (spike/smprobe, 2026-10-08). dxc.exe does the
// same at 0.35 s per shader under Wine (process start); this does 18,000 of them in minutes.
// Build (mingw on the M1): x86_64-w64-mingw32-g++ -O2 -std=c++17 -static -o dxdis.exe dxdis.cpp -lole32
// Run (Wine): dxdis.exe <windows folder of .dxil files> <windows path of dxcompiler.dll>  > out.txt
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <objidl.h>
#include <dxcapi.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static const CLSID kClsidCompiler = { 0x73e22d93, 0xe6ce, 0x47f3, { 0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0 } };
static const IID kIidCompiler3 = { 0x228b4687, 0x5a6a, 0x4730, { 0x90, 0x0c, 0x97, 0x02, 0xb2, 0x20, 0x3f, 0x54 } };
static const IID kIidResult = { 0x58346cda, 0xdde7, 0x4497, { 0x94, 0x61, 0x6f, 0x87, 0xaf, 0x5e, 0x06, 0x59 } };
static const IID kIidBlobUtf8 = { 0x3da636c9, 0xba71, 0x4024, { 0xa3, 0x01, 0x30, 0xcb, 0xf1, 0x25, 0x30, 0x5b } };
static const char *OPS[] = { "dx.op.quadVote.", "dx.op.textureGatherRaw.", "dx.op.sampleCmpLevel.", "dx.op.textureStoreSample." };

static int count(const char *text, size_t len, const char *needle) {
    int n = 0; size_t nl = strlen(needle), i = 0;
    while (i + nl <= len) { if (!memcmp(text + i, needle, nl)) { n++; i += nl; } else i++; }
    return n;
}

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: dxdis <folder> <dxcompiler.dll>\n"); return 1; }
    HMODULE m = LoadLibraryA(argv[2]);
    if (!m) { printf("LoadLibrary(%s) failed %lu\n", argv[2], GetLastError()); return 1; }
    DxcCreateInstanceProc create = (DxcCreateInstanceProc)GetProcAddress(m, "DxcCreateInstance");
    IDxcCompiler3 *comp = nullptr;
    HRESULT hr = create(kClsidCompiler, kIidCompiler3, (void **)&comp);
    if (FAILED(hr) || !comp) { printf("DxcCreateInstance(compiler) 0x%08lx\n", (unsigned long)hr); return 1; }
    std::string pattern = std::string(argv[1]) + "\\*.dxil";
    WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) { printf("no .dxil in %s\n", argv[1]); return 1; }
    int files = 0, failed = 0; std::vector<char> data;
    do {
        std::string path = std::string(argv[1]) + "\\" + fd.cFileName;
        FILE *f = fopen(path.c_str(), "rb"); if (!f) continue;
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        data.resize(n); fread(data.data(), 1, n, f); fclose(f);
        DxcBuffer buf = { data.data(), (SIZE_T)n, DXC_CP_ACP };
        IDxcResult *res = nullptr; IDxcBlobUtf8 *txt = nullptr;
        hr = comp->Disassemble(&buf, kIidResult, (void **)&res);
        if (SUCCEEDED(hr) && res) res->GetOutput(DXC_OUT_DISASSEMBLY, kIidBlobUtf8, (void **)&txt, nullptr);
        files++;
        if (!txt || !txt->GetStringLength()) { failed++; printf("%s FAILED 0x%08lx\n", fd.cFileName, (unsigned long)hr); }
        else {
            const char *t = txt->GetStringPointer(); size_t len = txt->GetStringLength();
            int c[4]; for (int i = 0; i < 4; i++) c[i] = count(t, len, OPS[i]);
            if (c[0] || c[1] || c[2] || c[3]) printf("%s quadVote=%d gatherRaw=%d sampleCmpLevel=%d storeSample=%d\n", fd.cFileName, c[0], c[1], c[2], c[3]);
        }
        if (txt) txt->Release(); if (res) res->Release();
        if (files % 1000 == 0) { fprintf(stderr, "%d files\n", files); fflush(stdout); }
    } while (FindNextFileA(h, &fd));
    printf("done: %d files disassembled, %d failed\n", files, failed);
    return 0;
}
