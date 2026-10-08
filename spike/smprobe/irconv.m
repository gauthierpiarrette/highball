// irconv: run DXIL blobs through the Metal shader converter that ships inside D3DMetal
// (libmetalirconverter.dylib in D3DMetal.framework/Resources) and then through Metal itself, to
// see which step refuses a Shader Model 6.7 shader and with what message. D3DMetal only prints
// "Failed to compile fragment function" and silently no-ops compute pipelines (smprobe, 2026-10-08).
//
// The converter is x86_64 only (it runs inside the Rosetta Wine process), so this runs under
// Rosetta too. Build on the M4:
//   clang -arch x86_64 -fobjc-arc -framework Metal -framework Foundation -o irconv irconv.m
// Run: ./irconv <libmetalirconverter.dylib> <dxil dir> [gpu family number] [macOS target, e.g. 15.0.0]
// The public API names and enum values follow Apple's metal_irconverter.h (Metal shader converter).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <dirent.h>

typedef struct IRCompiler IRCompiler; typedef struct IRObject IRObject; typedef struct IRError IRError; typedef struct IRMetalLibBinary IRMetalLibBinary;
typedef int IRShaderStage; typedef int IRBytecodeOwnership; typedef int IROperatingSystem; typedef int IRGPUFamily;
enum { IRShaderStageInvalid = 0, IRShaderStageVertex, IRShaderStageFragment, IRShaderStageHull, IRShaderStageDomain, IRShaderStageMesh, IRShaderStageAmplification, IRShaderStageGeometry,
       IRShaderStageRayGeneration, IRShaderStageAnyHit, IRShaderStageClosestHit, IRShaderStageMiss, IRShaderStageIntersection, IRShaderStageCallable, IRShaderStageStreamOut, IRShaderStageStageIn, IRShaderStageCompute };
static const char *stage_name(int s) {
    static const char *n[] = { "invalid", "vertex", "fragment", "hull", "domain", "mesh", "amplification", "geometry", "raygen", "anyhit", "closesthit", "miss", "intersection", "callable", "streamout", "stagein", "compute" };
    return s >= 0 && s <= 16 ? n[s] : "?";
}
static const char *err_name(unsigned c) {
    static const char *n[] = { "NoError", "ShaderRequiresRootSignature", "UnrecognizedRootSignatureDescriptor", "UnrecognizedParameterTypeInRootSignature",
        "ResourceNotReferencedByRootSignature", "ShaderIncompatibleWithDualSourceBlending", "UnsupportedWaveSize", "UnsupportedInstruction", "CompilationError",
        "FailedToSynthesizeStageInFunction", "FailedToSynthesizeStreamOutFunction", "FailedToSynthesizeIndirectIntersectionFunction", "UnableToVerifyModule",
        "UnableToLinkModule", "UnrecognizedDXILHeader", "InvalidRaytracingAttribute", "Unknown" };
    return c < sizeof n / sizeof *n ? n[c] : "?";
}

static IRCompiler *(*p_IRCompilerCreate)(void);
static void (*p_IRCompilerDestroy)(IRCompiler *);
static void (*p_IRCompilerSetEntryPointName)(IRCompiler *, const char *);
static void (*p_IRCompilerSetMinimumDeploymentTarget)(IRCompiler *, IROperatingSystem, const char *);
static void (*p_IRCompilerSetMinimumGPUFamily)(IRCompiler *, IRGPUFamily);
static IRObject *(*p_IRObjectCreateFromDXIL)(const uint8_t *, size_t, IRBytecodeOwnership);
static void (*p_IRObjectDestroy)(IRObject *);
static IRObject *(*p_IRCompilerAllocCompileAndLink)(IRCompiler *, const char *, const IRObject *, IRError **);
static IRShaderStage (*p_IRObjectGetMetalIRShaderStage)(const IRObject *);
static bool (*p_IRObjectGetMetalLibBinary)(const IRObject *, IRShaderStage, IRMetalLibBinary *);
static IRMetalLibBinary *(*p_IRMetalLibBinaryCreate)(void);
static void (*p_IRMetalLibBinaryDestroy)(IRMetalLibBinary *);
static size_t (*p_IRMetalLibGetBytecodeSize)(const IRMetalLibBinary *);
static size_t (*p_IRMetalLibGetBytecode)(const IRMetalLibBinary *, uint8_t *);
static uint32_t (*p_IRErrorGetCode)(const IRError *);
static const void *(*p_IRErrorGetPayload)(const IRError *);
static void (*p_IRErrorDestroy)(IRError *);

#define LOAD(n) do { p_##n = dlsym(h, #n); if (!p_##n) { printf("missing symbol %s\n", #n); return 1; } } while (0)

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: irconv <libmetalirconverter.dylib> <dxil dir> [gpu family] [macOS target]\n"); return 1; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    LOAD(IRCompilerCreate); LOAD(IRCompilerDestroy); LOAD(IRCompilerSetEntryPointName); LOAD(IRCompilerSetMinimumDeploymentTarget); LOAD(IRCompilerSetMinimumGPUFamily);
    LOAD(IRObjectCreateFromDXIL); LOAD(IRObjectDestroy); LOAD(IRCompilerAllocCompileAndLink); LOAD(IRObjectGetMetalIRShaderStage); LOAD(IRObjectGetMetalLibBinary);
    LOAD(IRMetalLibBinaryCreate); LOAD(IRMetalLibBinaryDestroy); LOAD(IRMetalLibGetBytecodeSize); LOAD(IRMetalLibGetBytecode); LOAD(IRErrorGetCode); LOAD(IRErrorGetPayload); LOAD(IRErrorDestroy);
    int family = argc > 3 ? atoi(argv[3]) : 0; const char *target = argc > 4 ? argv[4] : NULL;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("irconv: %s\nMetal device: %s, gpu family Apple9 %d, Metal3 %d\nconverter settings: gpu family %d, deployment target %s\n", argv[1], dev.name.UTF8String,
           [dev supportsFamily:MTLGPUFamilyApple9], [dev supportsFamily:MTLGPUFamilyMetal3], family, target ? target : "(default)");
    // A vertex function to pair converted fragment functions with: position only, which is all these fragments read.
    NSError *err = nil;
    id<MTLLibrary> vlib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 vmain(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }" options:nil error:&err];
    id<MTLFunction> vfn = [vlib newFunctionWithName:@"vmain"];

    NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(argv[2]) error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *n in names) {
        if (![n hasSuffix:@".dxil"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[@(argv[2]) stringByAppendingPathComponent:n]];
        printf("== %s (%lu bytes)\n", n.UTF8String, (unsigned long)d.length);
        IRObject *in = p_IRObjectCreateFromDXIL(d.bytes, d.length, 1);
        if (!in) { printf("  IRObjectCreateFromDXIL failed\n"); continue; }
        IRCompiler *c = p_IRCompilerCreate();
        p_IRCompilerSetEntryPointName(c, "main");
        if (family) p_IRCompilerSetMinimumGPUFamily(c, family);
        if (target) p_IRCompilerSetMinimumDeploymentTarget(c, 1 /* macOS */, target);
        IRError *e = NULL;
        IRObject *out = p_IRCompilerAllocCompileAndLink(c, "main", in, &e);
        if (!out) {
            unsigned code = e ? p_IRErrorGetCode(e) : 0xffff; const char *payload = e ? (const char *)p_IRErrorGetPayload(e) : NULL;
            printf("  converter REFUSED: code %u %s: %s\n", code, err_name(code), payload ? payload : "(no payload)");
            if (e) p_IRErrorDestroy(e);
            p_IRCompilerDestroy(c); p_IRObjectDestroy(in); continue;
        }
        int stage = p_IRObjectGetMetalIRShaderStage(out);
        IRMetalLibBinary *lib = p_IRMetalLibBinaryCreate();
        bool got = p_IRObjectGetMetalLibBinary(out, stage, lib);
        size_t sz = got ? p_IRMetalLibGetBytecodeSize(lib) : 0;
        printf("  converter OK: stage %s, metallib %zu bytes\n", stage_name(stage), sz);
        if (sz) {
            uint8_t *buf = malloc(sz); p_IRMetalLibGetBytecode(lib, buf);
            dispatch_data_t dd = dispatch_data_create(buf, sz, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            err = nil;
            id<MTLLibrary> ml = [dev newLibraryWithData:dd error:&err];
            if (!ml) printf("  Metal newLibraryWithData FAILED: %s\n", err.localizedDescription.UTF8String);
            else {
                NSArray *fns = ml.functionNames;
                id<MTLFunction> fn = [ml newFunctionWithName:fns.firstObject];
                printf("  Metal library loaded, functions %s\n", [fns componentsJoinedByString:@","].UTF8String);
                if (fn.functionType == MTLFunctionTypeKernel) {
                    err = nil; id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&err];
                    printf("  Metal compute pipeline: %s%s%s\n", ps ? "OK" : "FAILED", ps ? "" : ": ", ps ? "" : err.localizedDescription.UTF8String);
                } else if (fn.functionType == MTLFunctionTypeFragment) {
                    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
                    rd.vertexFunction = vfn; rd.fragmentFunction = fn; rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
                    err = nil; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
                    printf("  Metal render pipeline (with a plain vertex function): %s%s%s\n", ps ? "OK" : "FAILED", ps ? "" : ": ", ps ? "" : err.localizedDescription.UTF8String);
                } else printf("  Metal function type %d, not pipelined here\n", (int)fn.functionType);
            }
            free(buf);
        }
        p_IRMetalLibBinaryDestroy(lib); p_IRObjectDestroy(out); p_IRCompilerDestroy(c); p_IRObjectDestroy(in);
    }
    return 0;
}
