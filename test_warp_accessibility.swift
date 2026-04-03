import AppKit

guard let warpApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Warp" }) else {
    print("Warp not running")
    exit(1)
}

let pid = warpApp.processIdentifier
let appElement = AXUIElementCreateApplication(pid)

var windows: AnyObject?
AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windows)

guard let windowArray = windows as? [AXUIElement] else {
    print("No windows found")
    exit(1)
}

print("Found \(windowArray.count) Warp windows:")
for (i, window) in windowArray.enumerated() {
    var title: AnyObject?
    AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &title)
    let titleStr = title as? String ?? "(no title)"
    print("  [\(i)] \(titleStr)")
}
