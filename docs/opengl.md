# OpenGL startup, slow motion and missing textures

DXMT, DXVK, D3DMetal and vkd3d select Direct3D implementations. A program that
draws with OpenGL directly still uses its OpenGL driver when those settings change.
WineD3D also uses OpenGL on some engines, so an OpenGL error by itself does not
prove that a program uses OpenGL directly.

## Startup failures

Highball sets `CX_FWD_COMPAT_GL_CTX=1` for engines that support the CrossOver
switch. It lets programs request a forward-compatible OpenGL 3.2+ core context
when they omit that flag. If the log says `OS X only supports forward-compatible
3.2+ contexts`, remove any environment or per-program override setting the switch
to `0`, stop the environment and restart it.

That switch cannot supply newer functions in a legacy compatibility context.
In a local test of a 32-bit Cocos2d program on an Apple M3, Apple's OpenGL 2.1
compatibility context left a vertex-array-object function pointer null and the
program crashed during initialization. Patching the program to skip that call
only exposed another failure. Supplying a different OpenGL implementation got
past initialization without modifying the engine DLL.

## Mesa workaround for an isolated test environment

This is a manual compatibility experiment, not a shipped Highball graphics mode.
It was exercised with engine `x64-sikarugir10.0_6-r28` on an Apple M3. Other engine,
Mesa and MoltenVK combinations need their own verification.

1. Close programs in the source environment, then make a copy with
   `highball bottle duplicate "SOURCE" "OpenGL test"`. This command stops the source
   environment before copying it. Use the copy for the steps below.
2. Obtain the appropriate Windows build from
   [Mesa for Windows releases](https://github.com/pal1000/mesa-dist-win/releases/tag/24.3.4).
   The tested archive was `mesa3d-24.3.4-release-msvc.7z`, SHA-256
   `7ebc711ad1896ac88ab21e142f1017f8ff035f0f342bdb72fbb5e2eb881ba363`.
   Check the archive hash before extracting it.
3. For the tested **32-bit** program, place the archive's `x86/opengl32.dll`,
   `x86/libglapi.dll` and `x86/libgallium_wgl.dll` in the test prefix's
   `drive_c/windows/syswow64`, keeping copies of any replaced files. In a WoW64
   prefix, `syswow64` holds 32-bit DLLs and `system32` holds 64-bit DLLs. Do not
   mix architectures or DLLs from different Mesa releases.
4. In the test program's environment variables, set `WINEDLLOVERRIDES=opengl32=n`
   and `GALLIUM_DRIVER=zink`. The tested environment also had
   `MVK_SHADOW_IMPORT=1`, a switch in that engine's patched MoltenVK. Preserve any
   other DLL overrides the program needs.
   Merely copying the DLLs is insufficient if Wine still loads its builtin
   `opengl32`. A program started by an existing launcher inherits that launcher's
   environment, so stop it and relaunch it with the same settings.
5. Inspect the program's OpenGL renderer information. A renderer naming Zink and
   the Apple GPU confirms the GPU path. A requested `GALLIUM_DRIVER=zink` alone
   does not prove it ran. Test the affected scenes, not just the title screen.

Zink translates OpenGL through Vulkan and the engine's MoltenVK. A newer Mesa
build tested locally required a Vulkan capability unavailable in that MoltenVK
build and did not start. Mesa 24.3.4 did start through Zink and restored normal
movement speed in the tested program, but emitted unsupported-feature warnings
and some scenes still needed investigation. This is why this configuration is
not enabled globally.

The software renderer, `llvmpipe`, also got past initialization, but CPU use was
roughly 340% and the program ran in slow motion. Zink reduced it to roughly 75%
in that local comparison. These are observations from one program, not a
benchmark or a compatibility promise. Software rendering is useful to diagnose
a driver problem, but is a poor default for playing.

To roll back, stop the test environment and return to the source environment.
To restore the test prefix itself, restore its backed-up DLLs and remove the
OpenGL DLL override and Mesa environment settings. Remove any corresponding
registry override if one was added separately.

## White backgrounds or missing textures

Errors such as `OpenGL error 0x0501` from
`cocos2d::Texture2D::initWithMipmaps` mean texture initialization reported an
invalid value. They do not establish whether the image dimensions, format,
assets or driver caused it. Check unchanged original assets and capture the
actual OpenGL renderer, version and texture-size limit before changing drivers.

[WineMetalGL](https://github.com/metalsharp/WineMetalGL) is another OpenGL
implementation. A local Wine 11 / WineMetalGL 3.4.0 test started successfully and
reduced CPU use, but later produced these texture errors and white backgrounds.
A successful launch is not sufficient evidence to recommend it as a replacement
for every program or to call texture rendering fixed.

Highball's recovery advice recognizes explicit texture initialization failures,
software-renderer identity lines and the known core-context rejection. A null
pointer crash or an `opengl32` import alone is insufficient for that advice.
Reports retain OpenGL renderer identity and texture errors, along with the
selected Mesa driver switches, without including the full environment.
