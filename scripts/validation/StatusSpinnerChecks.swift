import AppKit
import QuartzCore

/// 不显示窗口、不请求辅助功能/录屏权限，只验证真实动画图层生命周期。
@main @MainActor struct StatusSpinnerChecks {
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NewPiStatusSpinnerView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
        view.configure(animate: true, color: .green, trackColor: .gray)
        precondition(view.arc.animationKeys() == nil, "未挂载不能运行")
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        guard let rotation = view.arc.animation(forKey: "rotation") as? CABasicAnimation else {
            fatalError("运行圆环必须有旋转动画")
        }
        precondition(rotation.keyPath == "transform.rotation.z" && rotation.duration == 1)
        precondition(rotation.repeatCount == .infinity && (rotation.toValue as? Double) == -2 * Double.pi)
        precondition(view.arc.path != nil && view.arc.bounds.size == view.bounds.size)
        // 用标记证明重复配置没有替换正在运行的动画。
        rotation.setValue("existing", forKey: "testMarker")
        view.arc.add(rotation, forKey: "rotation")
        for _ in 0..<100 { view.configure(animate: true, color: .green, trackColor: .gray) }
        precondition(view.arc.animation(forKey: "rotation")?.value(forKey: "testMarker") as? String == "existing")
        view.configure(animate: false, color: .green, trackColor: .gray)
        precondition(view.arc.animationKeys() == nil, "结束/减少动态效果必须停止")
        view.configure(animate: true, color: .green, trackColor: .gray)
        precondition(view.arc.animation(forKey: "rotation") != nil, "再次输出恢复旋转")
        view.removeFromSuperview()
        precondition(view.arc.animationKeys() == nil, "卸载清理动画")
        window.close()
        print("PASS: spinner rotation, stable updates, stop/restart and detach; no visible windows or permissions")
    }
}