import SwiftUI

struct UserMessageMarker: Identifiable, Equatable {
    let id: UUID
    let preview: String
}

struct NewPiUserMessageRail: View {
    let markers: [UserMessageMarker]
    let onSelect: (UUID) -> Void

    @State private var mouseY: CGFloat?
    @State private var isHovering = false

    private let defaultLineWidth: CGFloat = 14
    private let lineHeight: CGFloat = 2
    private let lineSpacing: CGFloat = 10
    /// 每个标记槽位的固定高度。lineCenterY 依赖它统一坐标，否则悬停高亮会偏离指针。
    private let lineSlotHeight: CGFloat = 14
    /// railBody 纵向 padding，与 lineCenterY 同一坐标系（mouseY 含该 padding）。
    private let railVerticalPadding: CGFloat = 10
    private let maxWidthBoost: CGFloat = 1.1
    private let magnificationSigma: CGFloat = 18
    private let previewMaxWidth: CGFloat = 280
    /// 预览气泡与轨道之间的水平间距，确保不压到刻度线及轨道背景。
    private let gapToRail: CGFloat = 40

    var body: some View {
        if markers.count >= 2 {
            railBody
                .overlay(alignment: .topLeading) {
                    // 预览作为 overlay 浮在轨道左侧，不参与布局，因此轨道位置不受它影响；
                    // 也不会导致轨道在指针下跳动。预览固定宽度（脱离轨道窄提案），
                    // 顶点对齐到悬停刻度，保证跟随指针。
                    if isHovering,
                       let markerID = selectedMarkerID,
                       let marker = markers.first(where: { $0.id == markerID }) {
                        previewBubble(for: marker)
                            .frame(width: previewMaxWidth, alignment: .leading)
                            .offset(
                                x: -(previewMaxWidth + gapToRail),
                                y: markerTopY(for: markerID)
                            )
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 8)
        }
    }

    private var railBody: some View {
        VStack(spacing: lineSpacing) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                markerLine(marker: marker, index: index)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, railVerticalPadding)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0.03))
        }
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
        // 不对手动悬停启动 spring：高亮与 dock 缩放应即时跟随指针，避免“对不准”
        // 以及点击命中区在动画中漂移。
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func markerLine(marker: UserMessageMarker, index: Int) -> some View {
        let centerY = lineCenterY(for: index)
        let scale = dockScale(centerY: centerY)
        let isSelected = selectedMarkerID == marker.id

        return Capsule(style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: defaultLineWidth * scale, height: lineHeight)
            .frame(width: 28, height: lineSlotHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(marker.id)
            }
            .accessibilityLabel("Jump to user message \(index + 1)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func previewBubble(for marker: UserMessageMarker) -> some View {
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
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
    }

    private var selectedMarkerID: UUID? {
        guard isHovering, let mouseY else { return nil }
        guard !markers.isEmpty else { return nil }

        let nearest = markers.enumerated().min { lhs, rhs in
            abs(lineCenterY(for: lhs.offset) - mouseY) < abs(lineCenterY(for: rhs.offset) - mouseY)
        }
        return nearest?.element.id
    }

    private func lineCenterY(for index: Int) -> CGFloat {
        railVerticalPadding + CGFloat(index) * (lineSlotHeight + lineSpacing) + lineSlotHeight / 2
    }

    /// 指定标记线顶部在轨道坐标系中的 y（预览气泡顶点对齐到该刻度）。
    private func markerTopY(for markerID: UUID) -> CGFloat {
        guard let idx = markers.firstIndex(where: { $0.id == markerID }) else { return 0 }
        return railVerticalPadding + CGFloat(idx) * (lineSlotHeight + lineSpacing)
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
        onSelect: { _ in }
    )
    .frame(width: 360, height: 280)
    .padding()
}
