import SwiftUI

struct UserMessageMarker: Identifiable, Equatable {
    let id: UUID
    let preview: String
}

struct NewPiUserMessageRail: View {
    let markers: [UserMessageMarker]
    /// 单文档路径（Phase 2）：条目在文档内的真实相对位置（0-1，JS 实测上报）。
    /// 非 nil 时 rail 按真实位置比例分布（minimap）；nil 时保持均匀刻度（遗留路径）。
    var positions: [UUID: Double]? = nil
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
            if let positions {
                ProportionalRailBody(
                    markers: markers,
                    positions: positions,
                    defaultLineWidth: defaultLineWidth,
                    lineHeight: lineHeight,
                    lineSlotHeight: lineSlotHeight,
                    maxWidthBoost: maxWidthBoost,
                    magnificationSigma: magnificationSigma,
                    previewMaxWidth: previewMaxWidth,
                    gapToRail: gapToRail,
                    onSelect: onSelect
                )
                .padding(.vertical, 8)
                .padding(.leading, 8)
            } else {
                uniformBody
            }
        }
    }

    private var uniformBody: some View {
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

// MARK: - 比例定位 rail（单文档路径，Phase 2）

/// minimap 模式：刻度按条目在文档内的真实相对位置（JS 实测上报）分布，轨道充满可用高度。
/// 自包含悬停/预览逻辑，与均匀刻度模式互不影响。
private struct ProportionalRailBody: View {
    let markers: [UserMessageMarker]
    let positions: [UUID: Double]
    let defaultLineWidth: CGFloat
    let lineHeight: CGFloat
    let lineSlotHeight: CGFloat
    let maxWidthBoost: CGFloat
    let magnificationSigma: CGFloat
    let previewMaxWidth: CGFloat
    let gapToRail: CGFloat
    let onSelect: (UUID) -> Void

    @State private var mouseY: CGFloat?
    @State private var isHovering = false

    private let trackWidth: CGFloat = 28

    var body: some View {
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
        onSelect: { _ in }
    )
    .frame(width: 360, height: 280)
    .padding()
}
