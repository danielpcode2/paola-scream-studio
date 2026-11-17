import AVFoundation
import Foundation

/// Projects live in <projects directory>/<fecha>/ with the screen recording(s), optional camera.mov and project.json.
enum ProjectStore {
    static var root: URL { Preferences.storedProjectsDirectory }
    static var exportsDirectory: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    static func videoURL(in folder: URL) -> URL { folder.appending(path: "recording.mov") }
    static func dataURL(in folder: URL) -> URL { folder.appending(path: "project.json") }
    static let cameraFileName = "camera.mov"

    static func segmentFileName(_ index: Int) -> String {
        index == 0 ? "recording.mov" : "recording-\(index + 1).mov"
    }

    static func isProject(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: dataURL(in: folder).path)
    }

    static func makeFolder(now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = root.appending(path: formatter.string(from: now), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func save(_ data: ProjectData, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(data).write(to: dataURL(in: folder), options: .atomic)
    }

    static func load(from folder: URL) throws -> ProjectData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectData.self, from: Data(contentsOf: dataURL(in: folder)))
    }

    static func recentProjects(limit: Int = 200) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter(isProject)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { $0 }
    }

    /// Moves the project to the Trash (recoverable).
    static func delete(_ folder: URL) throws {
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    /// Screen segments + camera of a project, aligned on one timeline (no edits applied).
    static func baseTimeline(for folder: URL, data: ProjectData) async throws -> RecordingTimeline {
        try await RecordingTimeline.load(
            screens: data.screenFiles.map { AVURLAsset(url: folder.appending(path: $0)) },
            camera: data.camera.map { AVURLAsset(url: folder.appending(path: $0.fileName)) },
            cameraOffset: data.camera?.offset ?? 0
        )
    }

    /// Timeline with the project's cuts, speed changes, intro/outro and audio effects.
    static func editedTimeline(for folder: URL, data: ProjectData) async throws -> RecordingTimeline {
        try await baseTimeline(for: folder, data: data).applying(data.settings, cursor: data.cursor, folder: folder)
    }

    /// Copies a music file into the project and returns its name inside the folder.
    static func importMusic(_ url: URL, into folder: URL) throws -> String {
        let name = "music." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        let destination = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: url, to: destination)
        return name
    }
}

struct StylePreset: Identifiable, Hashable {
    var name: String
    var settings: EditSettings

    var id: String { name }

    static func == (lhs: StylePreset, rhs: StylePreset) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// Look presets stored as `<name>.json` in the presets directory.
enum PresetStore {
    static var directory: URL { Preferences.storedPresetsDirectory }

    static func all() -> [StylePreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let settings = try? JSONDecoder().decode(EditSettings.self, from: data)
                else { return nil }
                return StylePreset(name: url.deletingPathExtension().lastPathComponent, settings: settings)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func load(_ name: String) -> StylePreset? { all().first { $0.name == name } }

    static func save(name: String, settings: EditSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings.styleOnly).write(to: url(for: name), options: .atomic)
    }

    static func delete(_ name: String) throws {
        try FileManager.default.trashItem(at: url(for: name), resultingItemURL: nil)
    }

    private static func url(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(safe).json")
    }
}
