import AVFoundation
import AppKit
import SwiftUI

/// "Show previous projects": every project in the projects folder.
struct ProjectsView: View {
    @ObservedObject private var app = AppModel.shared
    @State private var projects: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("projects.title")).font(.title2.bold())
                Spacer()
                Button(tr("menu.open_project"), systemImage: "folder") { app.openProjectPanel() }
                Button(tr("menu.new_recording"), systemImage: "record.circle") { app.newRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.recordAccent)
            }
            .padding(16)
            Divider()
            if projects.isEmpty {
                ContentUnavailableView(tr("projects.empty"), systemImage: "film.stack", description: Text(tr("projects.empty.detail")))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                        ForEach(projects, id: \.self) { folder in
                            ProjectCard(folder: folder) { reload() }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(app.objectWillChange) { DispatchQueue.main.async { reload() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func reload() {
        projects = ProjectStore.recentProjects()
    }
}

private struct ProjectCard: View {
    let folder: URL
    let changed: () -> Void
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    @State private var hovering = false

    var body: some View {
        let app = AppModel.shared
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let duration {
                    Text(formatClock(duration))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: hovering ? 2 : 0))
            Text(folder.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { app.open(folder) }
        .contextMenu {
            Button(tr("projects.open")) { app.open(folder) }
            Button(tr("settings.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Divider()
            Button(tr("delete"), role: .destructive) {
                if app.deleteProject(folder, confirm: true) { changed() }
            }
        }
        .help(tr("projects.open_hint"))
        .task(id: folder) { await loadPreview() }
    }

    private func loadPreview() async {
        guard let data = try? ProjectStore.load(from: folder) else { return }
        var total = 0.0
        for file in data.screenFiles {
            total += (try? await AVURLAsset(url: folder.appending(path: file)).load(.duration).seconds) ?? 0
        }
        duration = total
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: folder.appending(path: data.screenFiles[0])))
        generator.maximumSize = CGSize(width: 480, height: 300)
        if let image = try? await generator.image(at: CMTime(seconds: min(1, total / 2), preferredTimescale: 600)).image {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}
