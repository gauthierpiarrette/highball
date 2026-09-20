// CoCreateInstance the WMVideo Decoder (CLSID_CWMVDecMediaObject) as a DMO and as an MFT, and
// enumerate MFTs for WMV3 input, the three ways a prerequisite checker might ask "is the
// WMV decoder installed". Prints HRESULTs.
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <mfapi.h>
#include <mftransform.h>
#include <dmo.h>
#include <stdio.h>
static const CLSID CLSID_WMV = {0x82d353df,0x90bd,0x4382,{0x8b,0xc2,0x3f,0x61,0x92,0xb7,0x6e,0x34}};
int main(void){
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    printf("CoInitializeEx: 0x%08lx\n", hr);
    IUnknown *u = NULL;
    hr = CoCreateInstance(&CLSID_WMV, NULL, CLSCTX_INPROC_SERVER, &IID_IUnknown, (void**)&u);
    printf("CoCreateInstance(WMV decoder, IUnknown): 0x%08lx\n", hr); if (u) IUnknown_Release(u);
    IMediaObject *dmo = NULL;
    hr = CoCreateInstance(&CLSID_WMV, NULL, CLSCTX_INPROC_SERVER, &IID_IMediaObject, (void**)&dmo);
    printf("CoCreateInstance(WMV decoder, IMediaObject): 0x%08lx\n", hr); if (dmo) IMediaObject_Release(dmo);
    IMFTransform *mft = NULL;
    hr = CoCreateInstance(&CLSID_WMV, NULL, CLSCTX_INPROC_SERVER, &IID_IMFTransform, (void**)&mft);
    printf("CoCreateInstance(WMV decoder, IMFTransform): 0x%08lx\n", hr); if (mft) IMFTransform_Release(mft);
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    printf("MFStartup: 0x%08lx\n", hr);
    MFT_REGISTER_TYPE_INFO in = { MFMediaType_Video, {0x33564d57,0x0000,0x0010,{0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}} }; /* WMV3 */
    IMFActivate **acts = NULL; UINT32 n = 0;
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &in, NULL, &acts, &n);
    printf("MFTEnumEx(video decoder, WMV3 in): 0x%08lx count=%u\n", hr, n);
    for (UINT32 i = 0; i < n; i++) { WCHAR *name = NULL; UINT32 len = 0; if (SUCCEEDED(IMFActivate_GetAllocatedString(acts[i], &MFT_FRIENDLY_NAME_Attribute, &name, &len))) { printf("  mft: %ls\n", name); CoTaskMemFree(name); } IMFActivate_Release(acts[i]); }
    CoTaskMemFree(acts);
    /* DMO enumeration by category, the DirectShow-era way */
    IEnumDMO *e = NULL; hr = DMOEnum(&DMOCATEGORY_VIDEO_DECODER, 0, 0, NULL, 0, NULL, &e);
    printf("DMOEnum(video decoder): 0x%08lx\n", hr);
    if (e) { CLSID c; WCHAR *nm; ULONG got; while (IEnumDMO_Next(e, 1, &c, &nm, &got) == S_OK && got) { printf("  dmo: %ls\n", nm); CoTaskMemFree(nm); } IEnumDMO_Release(e); }
    MFShutdown(); CoUninitialize(); return 0;
}
