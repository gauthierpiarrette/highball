import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : ""
for w in list {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    let name = w["kCGWindowName"] as? String ?? ""
    let pid = w["kCGWindowOwnerPID"] as? Int ?? 0
    let id = w["kCGWindowNumber"] as? Int ?? 0
    let layer = w["kCGWindowLayer"] as? Int ?? 0
    let on = (w["kCGWindowIsOnscreen"] as? Bool) ?? false
    let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
    let bounds = "\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0)"
    if filter.isEmpty || (owner + " " + name).lowercased().contains(filter) {
        print("\(id)\tpid=\(pid)\t\(owner)\t|\(name)|\t\(bounds)\tlayer=\(layer)\ton=\(on)")
    }
}
