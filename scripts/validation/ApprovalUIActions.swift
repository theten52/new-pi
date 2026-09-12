import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func find(_ element: AXUIElement, role: String, text: String? = nil, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    let actualRole = attribute(element, kAXRoleAttribute) as? String
    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }
    if actualRole == role, text == nil || labels.contains(text!) { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let match = find(child, role: role, text: text, depth: depth + 1) { return match }
    }
    return nil
}

func waitFor(_ root: AXUIElement, role: String, text: String) -> AXUIElement {
    for _ in 0..<100 {
        if let element = find(root, role: role, text: text) { return element }
        usleep(50_000)
    }
    fatalError("Missing accessibility element: \(role) \(text)")
}

let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
NSRunningApplication(processIdentifier: pid)?.activate()
let allow = waitFor(app, role: kAXButtonRole, text: "允许一次")
let menu = find(app, role: "AXMenuButton", text: "不再询问…")
if mode == "high" {
    precondition(menu == nil, "High risk must not offer remembered grants")
    _ = AXUIElementPerformAction(allow, kAXPressAction as CFString)
} else {
    let menu = menu!
    _ = AXUIElementPerformAction(menu, kAXPressAction as CFString)
    usleep(300_000)
    let label = mode == "room" ? "本聊天室内允许 bash" : "一直允许 bash"
    let choice = find(menu, role: kAXMenuItemRole, text: label) ?? find(app, role: kAXMenuItemRole, text: label)
    precondition(choice != nil, "Expected grant scope missing")
    if mode == "room" {
        precondition(find(menu, role: kAXMenuItemRole, text: "一直允许 bash") == nil)
    }
    _ = AXUIElementPerformAction(choice!, kAXPressAction as CFString)
}
print("PASS AX component-only \(mode) (not transcript routing)")
