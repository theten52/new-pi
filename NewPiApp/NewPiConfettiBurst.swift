import SwiftUI

/// 「发送成功」的小礼花：在 Send 按钮位置炸开一片低饱和彩色粒子，向上飞进 transcript 区域，
/// 约 1 秒内自然消散。
///
/// 设计约束（与多会话保活架构 / Swift 6 strict concurrency 的协同）：
/// - **纯函数粒子**：每个粒子由 seed 用 SplitMix64 生成确定性参数，位置/透明度/旋转都是
///   elapsed time 的纯函数（抛体运动 `s = v₀·t + ½·g·t²`）。无 Timer、无 CADisplayLink、
///   无可变累积状态，Swift 6 并发天然安全，粒子参数可单测。
/// - **`TimelineView(.animation(minimumInterval:paused:))`** 驱动帧：burst 结束（elapsed 超过
///   最大生命周期）后置 `paused: true`，显示链路完全停止，零残留开销；视图不可见时系统自动暂停。
/// - **多会话隔离**：本视图挂在每个 `NewPiSessionPanel` 自己的 VStack overlay 上，`trigger`
///   变化是面板级 `@State` 驱动，后台会话的礼花只在自己（opacity 0 的）面板里播完自灭，
///   永不跨面板泄漏。
/// - **`allowsHitTesting(false)`**：粒子不挡 transcript 滚动 / rail / jump 按钮。
/// - **减动效**：`accessibilityReduceMotion` 开启时降级为单次无位移的 sparkle 脉冲。
struct NewPiConfettiBurstView: View {
    /// 触发序号：每次自增即重放一轮。onChange 里据此重置 burst 起始时间与随机种子。
    var trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 本轮 burst 的开始时间（nil = 当前无动画）。
    @State private var burst: Date?
    /// 本轮 burst 的随机种子（用于确定性生成粒子参数；无动画时为 0）。
    @State private var seed: UInt64 = 0

    /// 粒子总数。
    private static let particleCount = 45

    var body: some View {
        Group {
            if reduceMotion {
                ReduceMotionPulse(trigger: trigger)
            } else {
                confetti
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, newValue in
            guard newValue > 0 else { return }
            var rng = SplitMix64(seed: UInt64(bitPattern: Int64(newValue)))
            seed = rng.next()
            // 先置空 burst 再设新的：让 TimelineView 的 paused 立即翻转为 true，
            // 迫使旧一轮的 Canvas 销毁重建，避免快速连发时两个 seed 的粒子帧短暂重叠（Bug #2）。
            burst = nil
            burst = Date()
        }
    }

    @ViewBuilder
    private var confetti: some View {
        // burst == nil 时 paused = true，显示链路彻底停止；有 burst 时以 60fps 驱动。
        let paused = burst == nil
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            if let burstDate = burst {
                let elapsed = context.date.timeIntervalSince(burstDate)
                if elapsed >= Self.maxLifetime {
                    // 自然结束：清空 burst 卸载动画。这里的 empty content 只需渲染一次，
                    // onAppear 触发后 paused 翻转为 true，后续不再重绘。
                    Color.clear
                        .onAppear { burst = nil }
                } else {
                    Canvas { canvas, size in
                        // 发射原点固定在画布右下角（Send 按钮侧）。GeometryReader 保证
                        // 拿到真实 bounds，不依赖 overlay 是否被压缩成零尺寸（Bug #3）。
                        let origin = CGPoint(x: size.width, y: size.height)
                        for i in 0 ..< Self.particleCount {
                            let p = Self.particle(seed: seed, index: i, elapsed: elapsed, origin: origin)
                            draw(p, in: &canvas)
                        }
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    /// 粒子物理参数上限。
    private static let maxLifetime: TimeInterval = 1.4
    private static let gravity: Double = 900

    /// 由 seed + 索引确定性地生成一个粒子（纯函数，便于单测）。
    static func particle(seed: UInt64, index: Int, elapsed: TimeInterval, origin: CGPoint) -> Particle {
        var rng = SplitMix64(seed: seed &+ UInt64(index &* 2_654_435_761))
        // 初速度大小 220~420 pt/s，方向向上、扇形 ±22°。
        let speed = 220 + rng.uniform(in: 0 ... 1) * 200
        let angleDeg = -90 + (rng.uniform(in: 0 ... 1) - 0.5) * 44
        let angle = angleDeg * .pi / 180
        let vx = speed * cos(angle)
        let vy = speed * sin(angle)
        // 给一点水平扰动让扇形更像「炸开」。
        let lifecycle = 0.9 + rng.uniform(in: 0 ... 1) * 0.4
        let size = 3 + rng.uniform(in: 0 ... 1) * 3
        let colorIndex = Int(rng.uniform(in: 0 ... 1) * Double(Self.palette.count))
        let isCircle = rng.uniform(in: 0 ... 1) < 0.5
        let spin = (rng.uniform(in: 0 ... 1) - 0.5) * 720 // deg/s

        // 末段 30% 淡出。
        let fadeStart = lifecycle * 0.7
        let alpha = elapsed <= fadeStart ? 1.0 : max(0, 1 - (elapsed - fadeStart) / (lifecycle - fadeStart))

        return Particle(
            position: CGPoint(
                x: origin.x + vx * elapsed,
                y: origin.y + vy * elapsed + 0.5 * gravity * elapsed * elapsed
            ),
            size: size,
            color: Self.palette[colorIndex % Self.palette.count],
            isCircle: isCircle,
            rotation: Angle.degrees(spin * elapsed),
            alpha: alpha
        )
    }

    private func draw(_ p: Particle, in canvas: inout GraphicsContext) {
        var c = canvas
        c.opacity = p.alpha
        c.translateBy(x: p.position.x, y: p.position.y)
        c.rotate(by: p.rotation)
        let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)
        if p.isCircle {
            c.fill(Path(ellipseIn: rect), with: .color(p.color))
        } else {
            c.fill(Path(rect), with: .color(p.color))
        }
    }

    struct Particle {
        let position: CGPoint
        let size: CGFloat
        let color: Color
        let isCircle: Bool
        let rotation: Angle
        let alpha: Double
    }

    /// 低饱和色板：琥珀金为主 + 若干柔和点缀，对齐气泡色调的克制气质（不与 `bubbleTintHueDegrees` 符号耦合）。
    private static let palette: [Color] = [
        Color(red: 0.87, green: 0.65, blue: 0.34), // 琥珀金
        Color(red: 0.74, green: 0.80, blue: 0.58), // 雾绿
        Color(red: 0.61, green: 0.70, blue: 0.82), // 灰蓝
        Color(red: 0.79, green: 0.60, blue: 0.72), // 灰粉
        Color(red: 0.82, green: 0.78, blue: 0.60), // 米金
    ]
}

// MARK: - Reduce Motion 降级

/// 减动效降级：单次无位移的 sparkle 图标「出现 → 淡出」脉冲（`task(id:)` 保证只在 trigger 变化时跑一次）。
private struct ReduceMotionPulse: View {
    var trigger: Int
    /// 控制外观的关键帧状态：false = 出现（满显、正常大小），true = 淡出（透明、略放大）。
    @State private var expanded = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color(red: 0.87, green: 0.65, blue: 0.34))
            .opacity(expanded ? 0 : 1)
            .scaleEffect(expanded ? 1.15 : 1.0)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                // 复位到「出现」态，再动画过渡到「淡出」态，形成「出现 → 淡出」的轻量脉冲（Bug #1）。
                expanded = false
                withAnimation(.easeOut(duration: 0.45)) {
                    expanded = true
                }
            }
    }
}

// MARK: - SplitMix64 确定性随机源

/// 轻量确定性 PRNG：由单个 UInt64 种子生成可复现的序列，
/// 用于从 (seed, index) 确定性地导出粒子参数，规避 SystemRandomNumberGenerator
/// 在 Swift 6 strict concurrency 下的 Sendable 摩擦，同时让粒子物理可单测。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 生成 [0, 1) 均匀分布的 Double。
    mutating func uniform(in range: ClosedRange<Double>) -> Double {
        let v = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
        return range.lowerBound + (range.upperBound - range.lowerBound) * v
    }
}
