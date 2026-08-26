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
    private let maxWidthBoost: CGFloat = 1.1
    private let magnificationSigma: CGFloat = 18
    private let previewMaxWidth: CGFloat = 280

    var body: some View {
        if markers.count >= 2 {
            HStack(alignment: .center, spacing: 8) {
                previewBubble
                railBody
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private var previewBubble: some View {
        if isHovering,
           let markerID = selectedMarkerID,
           let marker = markers.first(where: { $0.id == markerID }) {
            Text(marker.preview)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: previewMaxWidth, alignment: .leading)
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
    }

    private var railBody: some View {
        VStack(spacing: lineSpacing) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                markerLine(marker: marker, index: index)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
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
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: mouseY)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private func markerLine(marker: UserMessageMarker, index: Int) -> some View {
        let centerY = lineCenterY(for: index)
        let scale = dockScale(centerY: centerY)
        let isSelected = selectedMarkerID == marker.id

        return Capsule(style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: defaultLineWidth * scale, height: lineHeight)
            .frame(width: 28, height: max(14, lineHeight * scale * 3))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(marker.id)
            }
            .accessibilityLabel("Jump to user message \(index + 1)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        CGFloat(index) * (lineHeight + lineSpacing) + lineHeight / 2
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
