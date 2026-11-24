import MacosCleanCore
import SwiftUI

enum MascotSettings {
    /// `UserDefaults` key: whether Bubbl floats over the window.
    static let showKey = "showMascot"
    /// `UserDefaults` key: the corner Bubbl was last dragged to (``MascotCorner`` raw value).
    static let cornerKey = "mascotCorner"
}

struct MascotSettingsSection: View {
    @AppStorage(MascotSettings.showKey) private var showMascot = true

    var body: some View {
        Section {
            Toggle("Show Bubbl", isOn: $showMascot)
        } header: {
            Text("Mascot")
        } footer: {
            Text("Bubbl floats in a corner of every section and reacts to scans, selections and cleanups. Drag it to another corner if it's in the way. When Reduce motion is on in System Settings › Accessibility, Bubbl holds still.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// View › Show Mascot (⌥⌘M), so a hidden Bubbl is easy to bring back.
struct MascotCommands: Commands {
    @AppStorage(MascotSettings.showKey) private var showMascot = true

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Mascot", isOn: $showMascot)
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}

enum MascotCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var anchor: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    /// From this corner, the content lies this way.
    var towardContent: CGVector { CGVector(dx: isLeading ? 1 : -1, dy: isBottom ? -1 : 1) }

    /// The corner nearest to `point` inside `size`.
    static func nearest(to point: CGPoint, in size: CGSize) -> MascotCorner {
        let leading = point.x < size.width / 2
        let bottom = point.y > size.height / 2
        switch (leading, bottom) {
        case (true, true): return .bottomLeading
        case (true, false): return .topLeading
        case (false, true): return .bottomTrailing
        case (false, false): return .topTrailing
        }
    }
}

/// Bubbl floating over the detail area of every section. Drag it anywhere; it snaps to the
/// nearest corner and stays there. In a bottom corner it rises above a section's bottom bar.
struct MascotOverlay: View {
    let state: AppState

    @AppStorage(MascotSettings.showKey) private var showMascot = true
    @AppStorage(MascotSettings.cornerKey) private var cornerRaw = MascotCorner.bottomTrailing.rawValue
    @State private var drag: CGSize = .zero
    @State private var reaction: BubblView.Reaction?

    /// Smaller than the old header version, so it covers less.
    private static let scale = 0.75
    private static let margin: CGFloat = 6
    /// Room for a section's bottom bar (selection bar, path bar).
    private static let bottomBarHeight: CGFloat = 60

    var body: some View {
        let scene = MascotDirector.scene(for: state)
        let corner = MascotCorner(rawValue: cornerRaw) ?? .bottomTrailing
        GeometryReader { geometry in
            Group {
                if showMascot {
                    bubbl(scene, corner: corner, area: geometry.size)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, Self.margin)
            .padding(.bottom, Self.margin + (corner.isBottom && scene.hasBottomBar ? Self.bottomBarHeight : 0))
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: corner.alignment)
        }
        .coordinateSpace(.named("mascotArea"))
        .motionAnimation(.smooth, value: showMascot)
        .motionAnimation(.snappy, value: scene.hasBottomBar)
        .onChange(of: scene) { old, new in
            if let kind = MascotDirector.reaction(from: old, to: new) { reaction = .init(kind: kind) }
        }
    }

    private func bubbl(_ scene: MascotScene, corner: MascotCorner, area: CGSize) -> some View {
        BubblView(
            mood: scene.mood,
            celebration: state.trash.celebration,
            leftoverCount: state.uninstaller.removed.count,
            onBlockedTap: { state.access.isShowingWelcome = true },
            onLeftoversTap: { state.section = .uninstaller },
            selectionShare: scene.selectionShare,
            reaction: reaction,
            carriedAppPath: scene.carriedAppPath,
            lookToward: corner.towardContent
        )
        .scaleEffect(Self.scale, anchor: corner.anchor)
        .offset(drag)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("mascotArea"))
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    // Glide from where it was dropped into the new corner.
                    Motion.animate(.snappy) {
                        cornerRaw = MascotCorner.nearest(to: value.location, in: area).rawValue
                        drag = .zero
                    }
                }
        )
    }
}
