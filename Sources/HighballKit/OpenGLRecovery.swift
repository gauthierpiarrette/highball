import Foundation

extension Recovery {
    /// Only the driver's or engine's own failure lines justify OpenGL advice. An opengl32
    /// import, a Vulkan extension list, or a null-pointer crash alone does not name the cause.
    public static func openGL(output: String) -> Recovery? {
        let lines = output.split(separator: "\n").map { $0.lowercased() }
        if lines.contains(where: { $0.contains("opengl error") && $0.contains("cctexture2d.cpp") && $0.contains("initwithmipmaps") }) {
            return Recovery(headline: "The game could not initialize some textures.",
                            meaning: "Its OpenGL texture setup reported an error, which can leave parts of the scene blank. The log does not establish whether the asset or the OpenGL driver rejected it. Try the original assets if they were modified, or an OpenGL driver verified for this program. The Direct3D graphics modes do not select a game's OpenGL driver.")
        }
        if lines.contains(where: {
            ($0.contains("gl.renderer:") || $0.contains("opengl renderer")) &&
                ($0.contains("llvmpipe") || $0.contains("softpipe") || $0.contains("software rasterizer"))
        }) {
            return Recovery(headline: "The game's OpenGL renderer is using the CPU.",
                            meaning: "Software rendering can cause stutter or slow motion. A compatible GPU OpenGL driver, such as Mesa Zink through Vulkan, may help. It must work with this engine's MoltenVK build. Changing the Direct3D graphics mode alone will not enable it.")
        }
        if lines.contains(where: { $0.contains("os x only supports forward-compatible 3.2+ contexts") }) {
            return Recovery(headline: "The game's OpenGL context was rejected.",
                            meaning: "Highball enables forward-compatible OpenGL contexts by default. Remove any CX_FWD_COMPAT_GL_CTX=0 override from the environment and this program, stop the environment, then launch again. If it still fails, include the launch log in a report.")
        }
        return nil
    }

    /// Use the same bounded read as bug reports, even when a session has produced a huge log.
    public static func openGL(log: URL) -> Recovery? {
        BugReport.boundedText(of: log).flatMap { openGL(output: $0) }
    }
}
