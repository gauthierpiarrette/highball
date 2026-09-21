// mfreadwrite stub: a Media Foundation source reader whose every stream ends at once.
//
// Placed beside a game's executable with a per-program native override (mfreadwrite=n,b), it
// replaces Wine's source reader for that program only. A movie opened through it "plays" for
// zero frames: the reader is created fine, reports its streams as ended on the first read, and
// the game's movie player moves on as it would after any video. That skips the intro videos
// RE Engine games play through Media Foundation, which deadlock inside Wine's WMV demuxer on
// macOS (highball#154, RE Village/2/3/4/7 sit on a black screen at under 1% CPU forever).
//
// A reader that merely fails to open (the first version of this stub) is not enough: RE Village
// then waits on the failed movie forever with the GPU drawing black frames. End-of-stream is what
// its player acts on.
//
// Both reader models are served: a synchronous ReadSample returns MF_SOURCE_READERF_ENDOFSTREAM,
// and when the caller registered an IMFSourceReaderCallback through the creation attributes
// (MF_SOURCE_READER_ASYNC_CALLBACK), ReadSample invokes OnReadSample with the same flag.
// Media-type queries fail, so a player that inspects the stream first gets "no video" and
// skips; one that reads first gets "ended" and skips. Sink writers are not provided (E_FAIL).
//
// Built with mingw (Scripts/build-mfstub.sh); no Wine builtin marker, so it is native.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <unknwn.h>

/* The few Media Foundation types and ids this stub needs, declared here so the build does not
 * depend on mingw's mfidl/mfreadwrite headers matching a given SDK. */
#define MF_SOURCE_READERF_ENDOFSTREAM 0x00000002
#define MF_SOURCE_READER_ANY_STREAM   0xFFFFFFFE
#define MF_E_INVALIDSTREAMNUMBER      ((HRESULT)0xC00D36B3)
DEFINE_GUID(IID_IMFSourceReader,        0x70ae66f2, 0xc809, 0x4e4f, 0x89, 0x15, 0xbd, 0xcb, 0x40, 0x6b, 0x79, 0x93);
DEFINE_GUID(IID_IMFSourceReaderCallback,0xdeec8d99, 0xfa1d, 0x4d82, 0x84, 0xc2, 0x2c, 0x89, 0x69, 0x94, 0x48, 0x67);
DEFINE_GUID(MF_SOURCE_READER_ASYNC_CALLBACK, 0x1e3dbeac, 0xbb43, 0x4c35, 0xb5, 0x07, 0xcd, 0x64, 0x44, 0x64, 0xc9, 0x65);

/* IMFSourceReaderCallback: IUnknown + OnReadSample, OnFlush, OnEvent. */
typedef struct IMFSourceReaderCallback IMFSourceReaderCallback;
typedef struct {
    HRESULT (WINAPI *QueryInterface)(IMFSourceReaderCallback *, REFIID, void **);
    ULONG   (WINAPI *AddRef)(IMFSourceReaderCallback *);
    ULONG   (WINAPI *Release)(IMFSourceReaderCallback *);
    HRESULT (WINAPI *OnReadSample)(IMFSourceReaderCallback *, HRESULT, DWORD, DWORD, LONGLONG, void *);
    HRESULT (WINAPI *OnFlush)(IMFSourceReaderCallback *, DWORD);
    HRESULT (WINAPI *OnEvent)(IMFSourceReaderCallback *, DWORD, void *);
} IMFSourceReaderCallbackVtbl;
struct IMFSourceReaderCallback { const IMFSourceReaderCallbackVtbl *lpVtbl; };

/* IMFSourceReader: IUnknown + 10 methods, in interface order. */
typedef struct Reader Reader;
typedef struct {
    HRESULT (WINAPI *QueryInterface)(Reader *, REFIID, void **);
    ULONG   (WINAPI *AddRef)(Reader *);
    ULONG   (WINAPI *Release)(Reader *);
    HRESULT (WINAPI *GetStreamSelection)(Reader *, DWORD, BOOL *);
    HRESULT (WINAPI *SetStreamSelection)(Reader *, DWORD, BOOL);
    HRESULT (WINAPI *GetNativeMediaType)(Reader *, DWORD, DWORD, void **);
    HRESULT (WINAPI *GetCurrentMediaType)(Reader *, DWORD, void **);
    HRESULT (WINAPI *SetCurrentMediaType)(Reader *, DWORD, DWORD *, void *);
    HRESULT (WINAPI *SetCurrentPosition)(Reader *, REFGUID, const PROPVARIANT *);
    HRESULT (WINAPI *ReadSample)(Reader *, DWORD, DWORD, DWORD *, DWORD *, LONGLONG *, void **);
    HRESULT (WINAPI *Flush)(Reader *, DWORD);
    HRESULT (WINAPI *GetServiceForStream)(Reader *, DWORD, REFGUID, REFIID, void **);
    HRESULT (WINAPI *GetPresentationAttribute)(Reader *, DWORD, REFGUID, PROPVARIANT *);
} ReaderVtbl;
struct Reader { const ReaderVtbl *lpVtbl; LONG ref; IMFSourceReaderCallback *callback; LONG turn; };

static HRESULT WINAPI r_QueryInterface(Reader *r, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IMFSourceReader)) { r->lpVtbl->AddRef(r); *out = r; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI r_AddRef(Reader *r) { return InterlockedIncrement(&r->ref); }
static ULONG WINAPI r_Release(Reader *r)
{
    ULONG n = InterlockedDecrement(&r->ref);
    if (!n) { if (r->callback) r->callback->lpVtbl->Release(r->callback); HeapFree(GetProcessHeap(), 0, r); }
    return n;
}
static HRESULT WINAPI r_GetStreamSelection(Reader *r, DWORD i, BOOL *sel) { (void)r; (void)i; if (sel) *sel = FALSE; return S_OK; }
static HRESULT WINAPI r_SetStreamSelection(Reader *r, DWORD i, BOOL sel) { (void)r; (void)i; (void)sel; return S_OK; }
static HRESULT WINAPI r_GetNativeMediaType(Reader *r, DWORD i, DWORD t, void **out) { (void)r; (void)i; (void)t; if (out) *out = NULL; return MF_E_INVALIDSTREAMNUMBER; }
static HRESULT WINAPI r_GetCurrentMediaType(Reader *r, DWORD i, void **out) { (void)r; (void)i; if (out) *out = NULL; return MF_E_INVALIDSTREAMNUMBER; }
static HRESULT WINAPI r_SetCurrentMediaType(Reader *r, DWORD i, DWORD *res, void *mt) { (void)r; (void)i; (void)res; (void)mt; return S_OK; }
static HRESULT WINAPI r_SetCurrentPosition(Reader *r, REFGUID g, const PROPVARIANT *p) { (void)r; (void)g; (void)p; return S_OK; }
static HRESULT WINAPI r_ReadSample(Reader *r, DWORD stream, DWORD flags, DWORD *actual, DWORD *sflags, LONGLONG *ts, void **sample)
{
    (void)flags;
    /* "Any stream": say every plausible stream ended, one per call, so a player waiting on a
     * particular index hears it within a few reads. */
    DWORD idx = (stream == MF_SOURCE_READER_ANY_STREAM) ? (DWORD)(InterlockedIncrement(&r->turn) & 3) : stream;
    if (r->callback) {
        r->callback->lpVtbl->OnReadSample(r->callback, S_OK, idx, MF_SOURCE_READERF_ENDOFSTREAM, 0, NULL);
        return S_OK;
    }
    if (actual) *actual = idx;
    if (sflags) *sflags = MF_SOURCE_READERF_ENDOFSTREAM;
    if (ts) *ts = 0;
    if (sample) *sample = NULL;
    return S_OK;
}
static HRESULT WINAPI r_Flush(Reader *r, DWORD i)
{
    if (r->callback) r->callback->lpVtbl->OnFlush(r->callback, i);
    return S_OK;
}
static HRESULT WINAPI r_GetServiceForStream(Reader *r, DWORD i, REFGUID s, REFIID iid, void **out) { (void)r; (void)i; (void)s; (void)iid; if (out) *out = NULL; return E_NOINTERFACE; }
static HRESULT WINAPI r_GetPresentationAttribute(Reader *r, DWORD i, REFGUID g, PROPVARIANT *v) { (void)r; (void)i; (void)g; (void)v; return E_FAIL; }

static const ReaderVtbl reader_vtbl = {
    r_QueryInterface, r_AddRef, r_Release, r_GetStreamSelection, r_SetStreamSelection, r_GetNativeMediaType,
    r_GetCurrentMediaType, r_SetCurrentMediaType, r_SetCurrentPosition, r_ReadSample, r_Flush,
    r_GetServiceForStream, r_GetPresentationAttribute
};

/* IMFAttributes::GetUnknown is slot 17 of the interface: IUnknown's three, then GetItem,
 * GetItemType, CompareItem, Compare, GetUINT32, GetUINT64, GetDouble, GetGUID, GetStringLength,
 * GetString, GetAllocatedString, GetBlobSize, GetBlob, GetAllocatedBlob, then GetUnknown. */
typedef HRESULT (WINAPI *GetUnknownFn)(IUnknown *, REFGUID, REFIID, void **);
static IMFSourceReaderCallback *callback_from(IUnknown *attributes)
{
    if (!attributes) return NULL;
    void **vtbl = *(void ***)attributes;
    GetUnknownFn get_unknown = (GetUnknownFn)vtbl[17];
    IMFSourceReaderCallback *cb = NULL;
    if (FAILED(get_unknown(attributes, &MF_SOURCE_READER_ASYNC_CALLBACK, &IID_IMFSourceReaderCallback, (void **)&cb))) return NULL;
    return cb;
}

static HRESULT create_reader(IUnknown *attributes, void **out)
{
    if (!out) return E_POINTER;
    Reader *r = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*r));
    if (!r) return E_OUTOFMEMORY;
    r->lpVtbl = &reader_vtbl; r->ref = 1; r->callback = callback_from(attributes);
    *out = r;
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI MFCreateSourceReaderFromByteStream(IUnknown *stream, IUnknown *attributes, void **out) { (void)stream; return create_reader(attributes, out); }
__declspec(dllexport) HRESULT WINAPI MFCreateSourceReaderFromURL(const WCHAR *url, IUnknown *attributes, void **out) { (void)url; return create_reader(attributes, out); }
__declspec(dllexport) HRESULT WINAPI MFCreateSourceReaderFromMediaSource(IUnknown *source, IUnknown *attributes, void **out) { (void)source; return create_reader(attributes, out); }
__declspec(dllexport) HRESULT WINAPI MFCreateSinkWriterFromURL(const WCHAR *url, IUnknown *stream, IUnknown *attributes, void **out) { (void)url; (void)stream; (void)attributes; if (out) *out = NULL; return E_FAIL; }
__declspec(dllexport) HRESULT WINAPI MFCreateSinkWriterFromMediaSink(IUnknown *sink, IUnknown *attributes, void **out) { (void)sink; (void)attributes; if (out) *out = NULL; return E_FAIL; }

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID p) { (void)h; (void)reason; (void)p; return TRUE; }
