import Foundation

/// The DLLs a Windows program links against, read from its import table and its delay-load
/// table. Delay-loaded ones count as much as the others: Path of Exile 2 binds Direct3D 12
/// that way (highball-db#53), and a program's need for an API is the same whichever table
/// names it. Anything the parser does not understand is an empty list, never a guess.
public enum PEImports {
    public static func dllNames(of file: URL) -> [String] {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        return dllNames(fromPE: d)
    }

    static func dllNames(fromPE d: Data) -> [String] {
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A else { return [] }
        let pe = Int(u32(d, 0x3C))
        guard pe + 24 < d.count, u32(d, pe) == 0x4550 else { return [] }
        let sections = Int(u16(d, pe + 6)), optSize = Int(u16(d, pe + 20)), opt = pe + 24
        guard opt + 2 <= d.count else { return [] }
        let plus = u16(d, opt) == 0x20B                       // PE32+ (64-bit) or PE32
        let imageBase = plus ? Int(u64(d, opt + 24)) : Int(u32(d, opt + 28))
        let ddCount = Int(u32(d, opt + (plus ? 108 : 92)))
        let dd = opt + (plus ? 112 : 96)                     // data directories: 8 bytes each
        var secs: [(va: Int, size: Int, raw: Int)] = []
        let table = opt + optSize
        for i in 0..<sections {
            let s = table + 40 * i
            guard s + 40 <= d.count else { return [] }
            // An old linker leaves VirtualSize 0 and only SizeOfRawData set; take the larger.
            secs.append((Int(u32(d, s + 12)), max(Int(u32(d, s + 8)), Int(u32(d, s + 16))), Int(u32(d, s + 20))))
        }
        func off(_ rva: Int) -> Int? {
            for s in secs where rva >= s.va && rva < s.va + max(s.size, 1) { return rva - s.va + s.raw }
            return nil
        }
        func name(atRVA rva: Int) -> String? {
            guard rva > 0, let o = off(rva), o < d.count else { return nil }
            var end = o
            while end < d.count, d[end] != 0, end - o < 256 { end += 1 }
            return String(data: d[o..<end], encoding: .ascii)
        }
        var names: [String] = []
        // Import directory (entry 1): 20-byte descriptors, the DLL name's RVA at +12, ended by
        // an all-zero descriptor.
        if ddCount > 1, u32(d, dd + 8 + 4) > 0, var e = off(Int(u32(d, dd + 8))) {
            while e + 20 <= d.count, names.count < 1024, u32(d, e + 12) != 0 || u32(d, e + 16) != 0 {
                if let n = name(atRVA: Int(u32(d, e + 12))) { names.append(n) }
                e += 20
            }
        }
        // Delay-load directory (entry 13): 32-byte descriptors, the name at +4, ended by a zero
        // name. Attribute bit 0 set means RVAs; clear (the original Visual C++ 6 form) means
        // virtual addresses, which the image base turns back into RVAs.
        if ddCount > 13, u32(d, dd + 8 * 13 + 4) > 0, var e = off(Int(u32(d, dd + 8 * 13))) {
            while e + 32 <= d.count, names.count < 2048, u32(d, e + 4) != 0 {
                let raw = Int(u32(d, e + 4))
                let rva = u32(d, e) & 1 == 1 ? raw : raw - imageBase
                if let n = name(atRVA: rva) { names.append(n) }
                e += 32
            }
        }
        return names
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { o + 2 <= d.count ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : 0 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        o + 4 <= d.count ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : 0
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
}

/// What a program's imports say it needs from the graphics stack.
public enum ProgramNeeds {
    static let direct3D12 = "d3d12.dll"
    /// Any of these means the program has another way to draw, so the environment's mode may
    /// well be the right one and choosing for it would override a working setup.
    static let otherGraphics: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d9.dll", "d3d8.dll", "ddraw.dll", "opengl32.dll", "vulkan-1.dll"]

    /// True when the program, or a DLL of its own that it links from its folder, imports
    /// Direct3D 12 and no other graphics API. Such a program cannot run on a mode without
    /// Direct3D 12 (DXMT, DXVK, Wine's own Direct3D), whatever the environment says: Farming
    /// Simulator 22 on a DXMT environment stops at "Shader model 6.0 is required" (highball#139)
    /// and an Unreal launcher on the same setup at its sign-in (highball-db#105). One level of
    /// the program's own DLLs is enough: Unity keeps its graphics in UnityPlayer.dll, other
    /// engines in a renderer DLL beside the executable; Windows' own DLLs are not in the folder.
    public static func direct3D12Only(program exe: URL) -> Bool {
        var names = Set(PEImports.dllNames(of: exe).map { $0.lowercased() })
        guard !names.isEmpty else { return false }
        let dir = exe.deletingLastPathComponent()
        for n in names.sorted() where n.hasSuffix(".dll") {
            let beside = dir.appending(path: n)
            guard FileManager.default.fileExists(atPath: beside.path) else { continue }
            names.formUnion(PEImports.dllNames(of: beside).map { $0.lowercased() })
        }
        return names.contains(direct3D12) && names.isDisjoint(with: otherGraphics)
    }

    /// An Unreal Engine 5 packaged build: `<root>/<Game>/Binaries/Win64/<exe>` with the engine's
    /// own `Engine/Binaries` beside it and IoStore containers (`.utoc`) under the game's Paks.
    /// Unreal links every renderer into one executable and loads d3d12.dll at run time, so its
    /// imports say nothing (The Last Caretaker's name dxgi and opengl32 only), and its choice of
    /// API sits in a config file inside the pak. Unreal 5 defaults to Direct3D 12 with Shader
    /// Model 6 and most titles ship no Direct3D 11 shaders, so on a mode without Direct3D 12
    /// they stop before the menu (highball#138, highball-db#105). Unreal 4 packages without
    /// IoStore and defaults to Direct3D 11, so it is left alone.
    public static func isUnreal5Build(program exe: URL) -> Bool {
        let win64 = exe.deletingLastPathComponent()
        let binaries = win64.deletingLastPathComponent()
        guard win64.lastPathComponent.lowercased() == "win64", binaries.lastPathComponent.lowercased() == "binaries" else { return false }
        let game = binaries.deletingLastPathComponent()
        let root = game.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appending(path: "Engine/Binaries").path) else { return false }
        let paks = game.appending(path: "Content/Paks")
        let entries = (try? fm.contentsOfDirectory(at: paks, includingPropertiesForKeys: nil)) ?? []
        return entries.contains { $0.pathExtension.lowercased() == "utoc" }
    }

    /// Whether the program needs a mode with Direct3D 12: its imports say so, or it is an
    /// Unreal 5 build. Used only when nothing more specific (a row, a per-game choice) says
    /// which mode to run.
    public static func wantsDirect3D12(program exe: URL) -> Bool {
        direct3D12Only(program: exe) || isUnreal5Build(program: exe)
    }
}
