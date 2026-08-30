import SwiftUI

struct UserMessageMarker: Identifiable, Equatable {
    let id: UUID
    let preview: String
}

/// 用户消息 minimap（单文档 transcript）：刻度按条目在文档内的真实相对位置
/// （JS 实测上报，0-1）比例分布，轨道充满可用高度；悬停放大 + 预览气泡，点击跳转。
struct NewPiUserMessageRail: View {
    let markers: [UserMessageMarker]
    /// 条目在文档内的真实相对位置（JS 实测上报）。未上报的条目退化为均匀位置。
    let positions: [UUID: Double]
    let onSelect: (UUID) -> Void

    @State private var mouseY: CGFloat?
    @State private var isHovering = false

    private let defaultLineWidth: CGFloat = 14
    private let lineHeight: CGFloat = 2
    /// 每个标记槽位的固定高度（悬停命中区）。
    private let lineSlotHeight: CGFloat = 14
    private let maxWidthBoost: CGFloat = 1.1
    private let magnificationSigma: CGFloat = 18
    private let previewMaxWidth: CGFloat = 280
    /// 预览气泡与轨道之间的水平间距，确保不压到刻度线及轨道背景。
    private let gapToRail: CGFloat = 40
    private let trackWidth: CGFloat = 28

    var body: some View {
        if markers.count >= 2 {
            GeometryReader { geo in
                let trackHeight = geo.size.height
                let hoveredID = hoveredMarkerID(trackHeight: trackHeight)
                ZStack(alignment: .topLeading) {
                    // 轨道背景（整高窄条）
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.06 : 0.03))
                        .frame(width: trackWidth, height: trackHeight)

                    ForEach(markers) { marker in
                        let centerY = centerY(for: marker.id, trackHeight: trackHeight)
                        Capsule(style: .continuous)
                            .fill(hoveredID == marker.id ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(width: defaultLineWidth * dockScale(centerY: centerY), height: lineHeight)
                            .frame(width: trackWidth, height: lineSlotHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(marker.id) }
                            .position(x: trackWidth / 2, y: centerY)
                            .accessibilityLabel("Jump to user message")
                    }

                    // 预览气泡：浮在轨道左侧，中心对齐悬停刻度
                    if let hoveredID,
                       let marker = markers.first(where: { $0.id == hoveredID }) {
                        Text(marker.preview)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .frame(width: previewMaxWidth, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                            }
                            .fixedSize()
                            .allowsHitTesting(false)
                            .position(
                                x: -(gapToRail + previewMaxWidth / 2),
                                y: centerY(for: hoveredID, trackHeight: trackHeight)
                            )
                    }
                }
                .frame(width: trackWidth, height: trackHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        isHovering = true
                        mouseY = location.y
                    case .ended:
                        isHovering = false
                        mouseY = nil
                    }
                }
            }
            .frame(width: trackWidth)
            .padding(.vertical, 8)
            .padding(.leading, 8)
        }
    }

    /// 条目刻度中心 y：按文档相对位置比例分布；未上报的条目退化为均匀位置。
    private func centerY(for id: UUID, trackHeight: CGFloat) -> CGFloat {
        let frac: Double
        if let reported = positions[id] {
            frac = reported
        } else if let index = markers.firstIndex(where: { $0.id == id }) {
            frac = (Double(index) + 0.5) / Double(markers.count)
        } else {
            frac = 0
        }
        let halfSlot = lineSlotHeight / 2
        return halfSlot + min(max(frac, 0), 1) * max(0, trackHeight - lineSlotHeight)
    }

    private func hoveredMarkerID(trackHeight: CGFloat) -> UUID? {
        guard isHovering, let mouseY else { return nil }
        return markers.min { lhs, rhs in
            abs(centerY(for: lhs.id, trackHeight: trackHeight) - mouseY)
                < abs(centerY(for: rhs.id, trackHeight: trackHeight) - mouseY)
        }?.id
    }

    private func dockScale(centerY: CGFloat) -> CGFloat {
        guard isHovering, let mouseY else { return 1 }
        let distance = mouseY - centerY
        let boost = maxWidthBoost * exp(-(distance * distance) / (2 * magnificationSigma * magnificationSigma))
        return 1 + boost
    }
}

#Preview("User message rail") {
    NewPiUserMessageRail(
        markers: [
            UserMessageMarker(id: UUID(), preview: "帮我看一下 scroll 逻辑"),
            UserMessageMarker(id: UUID(), preview: "继续，顺便加测试"),
            UserMessageMarker(id: UUID(), preview: "OK，按 plan 实现 rail"),
        ],
        positions: [:],
        onSelect: { _ in }
    )
    .frame(width: 360, height: 280)
    .padding()
}
