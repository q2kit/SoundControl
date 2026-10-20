import SwiftUI

// Small building blocks shared by the main page and the Settings page.

/// Mute button, slider and percentage — the same row for the system output, a routed device or an app.
struct VolumeRow: View {
    let volume: Float
    let muted: Bool
    let onToggleMute: () -> Void
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            MuteButton(muted: muted, volume: volume, action: onToggleMute)
            VolumeSlider(value: Binding(get: { volume }, set: onChange), muted: muted)
            PercentLabel(value: volume)
        }
    }
}

/// A thin 0…1 slider with a round knob, styled like Control Center.
struct VolumeSlider: View {
    @Binding var value: Float
    var muted: Bool

    @State private var dragging = false
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(value)
            let knob: CGFloat = dragging ? 16 : 14

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(muted ? AnyShapeStyle(Color.secondary.opacity(0.5)) : AnyShapeStyle(Color.accentColor))
                    .frame(width: max(trackHeight, fraction * width), height: trackHeight)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08)))
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * (width - knob))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Float(min(max(0, drag.location.x / width), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.1), value: dragging)
        }
        .frame(height: 18)
    }
}

struct MuteButton: View {
    let muted: Bool
    let volume: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(muted ? Color.red : Color.primary.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(muted ? 0.0 : 0.08)))
                .background(Circle().fill(Color.red.opacity(muted ? 0.15 : 0)))
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if muted { return "speaker.slash.fill" }
        switch volume {
        case 0: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct PercentLabel: View {
    let value: Float

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
    }
}

/// A capsule button that opens the list of output devices.
struct DevicePicker: View {
    let title: String
    let symbol: String?
    let devices: [OutputDevice]
    let selectedUID: String?
    /// Adds a "follow the system" entry, selected when `selectedUID` is nil.
    let includeDefault: Bool
    let maxWidth: CGFloat
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            if includeDefault {
                Toggle(isOn: Binding(get: { selectedUID == nil }, set: { _ in onSelect(nil) })) {
                    MenuLabel("Follow System", systemImage: "gearshape")
                }
                Divider()
            }
            ForEach(devices) { device in
                Toggle(isOn: Binding(get: { selectedUID == device.uid }, set: { _ in onSelect(device.uid) })) {
                    MenuLabel(verbatim: device.name, systemImage: device.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: maxWidth)
            .background(Capsule().fill(.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A menu item with its icon. On macOS a plain `Label` inside a menu shows only its title.
struct MenuLabel: View {
    let title: Text
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    /// For names that must not be translated, such as a device name.
    init(verbatim title: String, systemImage: String) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
    }

    var body: some View {
        Label { title } icon: { Image(systemName: systemImage) }
            .labelStyle(.titleAndIcon)
    }
}

struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

struct IconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(tint.gradient))
    }
}

struct CardBackground: View {
    let cornerRadius: CGFloat
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.primary.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06))
            )
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

/// A round icon button that lights up on hover (footer, back button, "show again").
struct FooterButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

/// Inside a menu bar window a ScrollView has no natural height and collapses to nothing,
/// so this one measures its content and takes that height, scrolling only past `maxHeight`.
struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .scrollIndicators(.never)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
