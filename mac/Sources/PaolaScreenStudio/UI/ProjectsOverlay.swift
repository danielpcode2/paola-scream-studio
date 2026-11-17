import AVFoundation
import AppKit
import SwiftUI

/// Thumbnail, camera frame, length and date of a project, for project cards.
struct ProjectPreview {
    var image: NSImage?
    var camera: NSImage?
    var duration: Double = 0
    var date: Date?

    static func load(_ folder: URL) async -> ProjectPreview {
        guard let data = try? ProjectStore.load(from: folder) else { return ProjectPreview() }
        var preview = ProjectPreview(date: data.createdAt)
        for file in data.screenFiles {
            preview.duration += (try? await AVURLAsset(url: folder.appending(path: file)).load(.duration).seconds) ?? 0
        }
        let time = CMTime(seconds: min(1, preview.duration / 2), preferredTimescale: 600)
        preview.image = await frame(folder.appending(path: data.screenFiles[0]), at: time, maxSize: CGSize(width: 640, height: 400))
        if let camera = data.camera {
            preview.camera = await frame(folder.appending(path: camera.fileName), at: time, maxSize: CGSize(width: 240, height: 240))
        }
        return preview
    }

    private static func frame(_ url: URL, at time: CMTime, maxSize: CGSize) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// "Yesterday", "3 days ago"… in the app language.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current.rawValue)
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Full-screen, blurred projects panel shown behind the recording toolbar (folder button).
@MainActor
final class ProjectsOverlayController {
    private var panel: FloatingPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(on screen: NSScreen) {
        // One level below the toolbar and camera bubble so clicking the panel never covers them.
        let panel = panel ?? FloatingPanel(frame: screen.frame, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1))
        panel.onCancel = { AppModel.shared.hideProjectsOverlay() }
        panel.host(ProjectsOverlayView())
        panel.setFrame(screen.frame, display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

private struct ProjectsOverlayView: View {
    @State private var projects: [URL] = []
    @State private var query = ""

    private var filtered: [URL] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return projects }
        return projects.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let app = AppModel.shared
        ZStack(alignment: .topLeading) {
            VisualEffectBackground()
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.15), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Button { app.hideProjectsOverlay() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, .white)
                    }
                    .buttonStyle(.plain)
                    .help(tr("close"))
                    Spacer()
                    GlassButton(title: tr("menu.show_projects"), icon: "folder") {
                        app.hideProjectsOverlay()
                        app.showProjects()
                    }
                    GlassButton(title: tr("menu.open_project"), icon: "folder.badge.plus") {
                        app.hideProjectsOverlay()
                        app.openProjectPanel()
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                        TextField(tr("projects.search"), text: $query)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 280, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                }

                if filtered.isEmpty {
                    Text(projects.isEmpty ? tr("projects.empty") : tr("projects.no_results"))
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            ForEach(filtered, id: \.self) { folder in
                                OverlayProjectCard(folder: folder)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onAppear { projects = ProjectStore.recentProjects(limit: 40) }
    }
}

private struct OverlayProjectCard: View {
    let folder: URL
    @State private var preview = ProjectPreview()
    @State private var hovering = false

    var body: some View {
        Button {
            AppModel.shared.hideProjectsOverlay()
            AppModel.shared.closeToolbar()
            AppModel.shared.open(folder)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
                    if let image = preview.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let camera = preview.camera {
                        Image(nsImage: camera).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 82, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    }
                    if preview.duration > 0 {
                        Text(formatClock(preview.duration))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .frame(width: 340, height: 214)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(hovering ? 0.9 : 0.15), lineWidth: hovering ? 2 : 1))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)

                HStack(spacing: 10) {
                    Text(folder.lastPathComponent).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(ProjectPreview.relative(preview.date)).font(.headline).foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: 340, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tr("projects.open")) { AppModel.shared.open(folder) }
            Button(tr("settings.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Divider()
            Button(tr("delete"), role: .destructive) { AppModel.shared.deleteProject(folder, confirm: true) }
        }
        .task(id: folder) { preview = await ProjectPreview.load(folder) }
    }
}

private struct GlassButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.16 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Live blur of whatever is behind the window (desktop and other apps).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
