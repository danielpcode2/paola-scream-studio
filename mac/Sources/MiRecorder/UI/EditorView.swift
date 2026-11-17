import AppKit
import SwiftUI
import UniformTypeIdentifiers

func formatTime(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = total - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, secs)
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

/// Editor palette: near-black surfaces with a violet accent.
enum EditorStyle {
    static let background = Color(white: 0.055)
    static let surface = Color(white: 0.1)
    static let raised = Color(white: 0.14)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.42, green: 0.32, blue: 1)
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var prefs = Preferences.shared
    @State private var showExport = false
    @State private var exportOptions = Preferences.shared.quickExport
    @State private var askPresetName = false
    @State private var presetName = ""
    @State private var tab: InspectorTab = .background
    @State private var timelineZoom: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                ToolPalette(model: model)
                    .padding(.leading, 14)
                VStack(spacing: 10) {
                    PreviewBar(model: model)
                    PlayerView(player: model.player)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EditorStyle.stroke))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                InspectorPanel(model: model, tab: $tab)
                    .padding(.trailing, 14)
                    .padding(.vertical, 10)
            }
            TransportBar(model: model, timelineZoom: $timelineZoom)
            TimelineArea(model: model, zoom: timelineZoom)
                .frame(height: model.hasCamera ? 214 : 182)
        }
        .background(EditorStyle.background)
        .environment(\.colorScheme, .dark)
        .tint(EditorStyle.accent)
        .onChange(of: model.selection) { _, selection in
            if selection != nil { tab = .selection }
        }
        .overlay(alignment: .top) {
            if let message = model.message {
                Text(message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 60)
                    .onTapGesture { model.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.message == message { model.message = nil }
                    }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(options: $exportOptions) {
                showExport = false
                guard let url = AppModel.shared.chooseExportURL(name: model.title, format: exportOptions.format) else { return }
                Task { await model.export(options: exportOptions, to: url) }
            } cancel: {
                showExport = false
            }
        }
        .alert(tr("presets.save_title"), isPresented: $askPresetName) {
            TextField(tr("presets.name"), text: $presetName)
            Button(tr("save")) { model.saveAsPreset(named: presetName) }
            Button(tr("cancel"), role: .cancel) {}
        }
        // Editing shortcuts are handled by EditorModel.handleKey (ignored while typing in a text field).
        .onChange(of: model.exportRequested) { _, requested in
            guard requested else { return }
            model.exportRequested = false
            openExport()
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 6) {
                Color.clear.frame(width: 72) // traffic lights
                BarButton(icon: "folder", help: tr("settings.show_in_finder")) { model.revealInFinder() }
                BarButton(icon: "trash", help: tr("delete")) { AppModel.shared.deleteProject(model.folder, confirm: true) }
                Spacer()
                BarButton(icon: "record.circle", help: tr("menu.new_recording")) { AppModel.shared.newRecording() }
                Divider().frame(height: 22).padding(.horizontal, 4)
                BarButton(icon: "arrow.uturn.backward", help: tr("editor.undo")) { model.undo() }
                    .disabled(model.undoStack.isEmpty)
                BarButton(icon: "arrow.uturn.forward", help: tr("editor.redo")) { model.redo() }
                    .disabled(model.redoStack.isEmpty)
                Divider().frame(height: 22).padding(.horizontal, 4)
                presetsMenu
                if !prefs.autosave {
                    BarButton(icon: "square.and.arrow.down", help: tr("save")) { model.save() }
                        .disabled(!model.isDirty)
                }
                if let progress = model.exportProgress {
                    ProgressView(value: progress).frame(width: 140).padding(.horizontal, 8)
                } else {
                    Button { openExport() } label: {
                        Label(tr("editor.export"), systemImage: "square.and.arrow.up.fill")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(EditorStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.duration == 0)
                }
            }
            HStack(spacing: 6) {
                Text(model.title).font(.callout.weight(.medium))
                if model.isDirty { Circle().fill(.secondary).frame(width: 6, height: 6).help(tr("editor.unsaved")) }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(EditorStyle.background)
        .overlay(alignment: .bottom) { Rectangle().fill(EditorStyle.stroke).frame(height: 1) }
    }

    private var presetsMenu: some View {
        Menu {
            if model.presets.isEmpty {
                Text(tr("presets.none"))
            }
            ForEach(model.presets) { preset in
                Button(preset.name) { model.apply(preset) }
            }
            Divider()
            Button(tr("presets.save_current")) {
                presetName = ""
                askPresetName = true
            }
            if !model.presets.isEmpty {
                Picker(tr("presets.default"), selection: $prefs.defaultPresetName) {
                    Text(tr("presets.no_default")).tag(String?.none)
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.name)) }
                }
                Menu(tr("presets.delete")) {
                    ForEach(model.presets) { preset in
                        Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                    }
                }
            }
            Divider()
            Button(tr("presets.show_folder")) {
                try? FileManager.default.createDirectory(at: PresetStore.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(PresetStore.directory)
            }
        } label: {
            Label(tr("presets.title"), systemImage: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .onAppear { model.reloadPresets() }
    }

    private func openExport() {
        guard model.duration > 0, model.exportProgress == nil else { return }
        exportOptions = prefs.quickExport
        showExport = true
    }
}

/// Icon button used in the editor's bars.
private struct BarButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering && isEnabled ? 0.1 : 0)))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Left floating palette: add items at the playhead.
private struct ToolPalette: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let t = model.currentTime
        VStack(spacing: 4) {
            BarButton(icon: "plus.magnifyingglass", help: tr("add.zoom")) { model.addZoom(at: t) }
            BarButton(icon: "scissors", help: tr("add.cut")) { model.addEdit(at: t, speed: 0) }
            BarButton(icon: "hare", help: tr("add.speed")) { model.addEdit(at: t, speed: 2) }
            Divider().frame(width: 24).padding(.vertical, 4)
            ForEach(AnnotationKind.allCases) { kind in
                BarButton(icon: kind.icon, help: tr("annotation.kind.\(kind.rawValue)")) { model.addAnnotation(at: t, kind: kind) }
            }
            if model.hasCamera {
                Divider().frame(width: 24).padding(.vertical, 4)
                BarButton(icon: "person.crop.rectangle.fill", help: tr("camera.layout.fullscreen")) { model.addCameraLayout(at: t, layout: .fullscreen) }
                BarButton(icon: "person.crop.circle.badge.plus", help: tr("camera.layout.large")) { model.addCameraLayout(at: t, layout: .large) }
                BarButton(icon: "person.crop.circle.badge.xmark", help: tr("camera.layout.hidden")) { model.addCameraLayout(at: t, layout: .hidden) }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(EditorStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EditorStyle.stroke))
    }
}

/// Above the preview: canvas format and preview quality.
private struct PreviewBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 18) {
            Menu {
                Picker(tr("editor.format"), selection: $model.settings.aspect) {
                    ForEach(CanvasAspect.allCases) { aspect in
                        Text(aspect == .source ? tr("editor.original") : aspect.label).tag(aspect)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.settings.aspect == .source ? tr("editor.original") : model.settings.aspect.label, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Menu {
                Picker(tr("preview.quality"), selection: $model.previewQuality) {
                    ForEach(EditorModel.PreviewQuality.allCases) { Text(tr("preview.quality.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(tr("preview.quality")): \(tr("preview.quality.\(model.previewQuality.rawValue)"))", systemImage: "gauge.with.dots.needle.67percent")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }
}

/// Play controls, times, playback speed and timeline zoom.
private struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @Binding var timelineZoom: Double

    var body: some View {
        HStack(spacing: 14) {
            BarButton(icon: "scissors", help: tr("add.cut")) { model.addEdit(at: model.currentTime, speed: 0) }
            Spacer()
            Text(formatTime(model.playerTime)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            BarButton(icon: "backward.end.fill", help: tr("transport.previous")) { model.jump(forward: false) }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            BarButton(icon: "forward.end.fill", help: tr("transport.next")) { model.jump(forward: true) }
            Text(formatTime(model.finalDuration)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
                .help(tr("editor.final_time_hint"))
            Spacer()
            Menu {
                Picker(tr("transport.speed"), selection: $model.playbackRate) {
                    ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text("\(String(format: "%g", $0))×").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("\(String(format: "%g", model.playbackRate))×").font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr("transport.speed"))
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $timelineZoom, in: 1...8).frame(width: 110)
                .help(tr("transport.timeline_zoom"))
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }
}

/// Export format, frame rate, resolution and compression (pre-filled with the Quick export settings).
struct ExportSheet: View {
    @Binding var options: ExportOptions
    let export: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("editor.export")).font(.title2.bold())
            ExportOptionsForm(options: $options)
            HStack {
                Spacer()
                Button(tr("cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(tr("export.choose_file"), action: export)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.recordAccent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Shared by the export sheet and Settings › Quick export.
struct ExportOptionsForm: View {
    @Binding var options: ExportOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(tr("export.format"), systemImage: "film")
                    Picker("", selection: $options.format) {
                        ForEach(ExportOptions.Format.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(tr("export.frame_rate"), systemImage: "camera.aperture")
                    Picker("", selection: $options.fps) {
                        ForEach(ExportOptions.frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("export.resolution"), systemImage: "rectangle.dashed")
                Picker("", selection: $options.resolution) {
                    ForEach(ExportOptions.Resolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if options.format == .mp4 {
                VStack(alignment: .leading, spacing: 8) {
                    Label(tr("export.compression"), systemImage: "scribble")
                    Picker("", selection: $options.compression) {
                        ForEach(ExportOptions.Compression.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(options.compression.detail).font(.callout).foregroundStyle(.secondary)
                    Text(tr("export.speed_note")).font(.caption).foregroundStyle(.secondary)
                }
            } else if options.format == .gif {
                Text(tr("export.gif_note")).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(tr("export.prores_note")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Inspector

enum InspectorTab: String, CaseIterable, Identifiable {
    case selection, background, cursor, camera, zoom, keys, audio, titles, trim

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .selection: "square.dashed.inset.filled"
        case .background: "photo.on.rectangle.angled"
        case .cursor: "cursorarrow"
        case .camera: "person.crop.square"
        case .zoom: "plus.magnifyingglass"
        case .keys: "command"
        case .audio: "speaker.wave.2"
        case .titles: "textformat.size"
        case .trim: "timeline.selection"
        }
    }
}

/// Vertical icon tabs + one settings panel at a time.
private struct InspectorPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var tab: InspectorTab

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                ForEach(InspectorTab.allCases) { item in
                    if item != .camera || model.hasCamera {
                        Button { tab = item } label: {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 38, height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(tab == item ? EditorStyle.accent.opacity(0.25) : .clear))
                                .foregroundStyle(tab == item ? EditorStyle.accent : .secondary)
                                .overlay(alignment: .topTrailing) {
                                    if item == .selection, model.selection != nil {
                                        Circle().fill(EditorStyle.accent).frame(width: 6, height: 6).offset(x: -4, y: 4)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tr("inspector.tab.\(item.rawValue)"))
                    }
                }
            }
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(tr("inspector.tab.\(tab.rawValue)"))
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                Form { content }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14).fill(EditorStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EditorStyle.stroke))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .selection:
            if let selection = model.selection {
                switch selection {
                case .zoom:
                    if let segment = model.selectedZoom { ZoomInspector(model: model, segment: segment) }
                case .edit:
                    if let edit = model.selectedEdit { EditInspector(model: model, edit: edit) }
                case .camera:
                    if let layout = model.selectedCameraLayout { CameraLayoutInspector(model: model, segment: layout) }
                case .annotation:
                    if let annotation = model.selectedAnnotation { AnnotationInspector(model: model, annotation: annotation) }
                }
            } else {
                Text(tr("inspector.hint")).font(.callout).foregroundStyle(.secondary)
            }
        case .background:
            Section {
                Picker(tr("background.kind"), selection: $model.settings.backgroundKind) {
                    ForEach(BackgroundKind.allCases) { Text(tr("background.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch model.settings.backgroundKind {
                case .gradient:
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 10) {
                        ForEach(GradientBackground.presets, id: \.self) { preset in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: [preset.start.color, preset.end.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white, lineWidth: model.settings.background == preset ? 2 : 0))
                                .help(preset.name)
                                .onTapGesture { model.settings.background = preset }
                        }
                    }
                case .color:
                    ColorPicker(tr("background.color"), selection: Binding(
                        get: { model.settings.backgroundColor.color },
                        set: { model.settings.backgroundColor = RGBAColor($0) }
                    ), supportsOpacity: false)
                case .image:
                    HStack {
                        Text(model.settings.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? tr("background.no_image"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(tr("background.choose_image")) { model.chooseBackgroundImage() }
                    }
                case .wallpaper:
                    Text(tr("background.wallpaper_hint")).font(.caption).foregroundStyle(.secondary)
                }
                LabeledSlider(tr("background.blur"), value: $model.settings.backgroundBlur, range: 0...1)
            }
            Section {
                LabeledSlider(tr("editor.padding"), value: $model.settings.padding, range: 0...0.2)
                LabeledSlider(tr("editor.corners"), value: $model.settings.cornerRadius, range: 0...0.08)
                LabeledSlider(tr("editor.shadow"), value: $model.settings.shadow, range: 0...1)
                Picker(tr("frame.window"), selection: $model.settings.windowFrame) {
                    ForEach(WindowFrameStyle.allCases) { Text(tr("frame.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        case .cursor:
            Section {
                Toggle(tr("editor.show_cursor"), isOn: $model.settings.showCursor)
                Picker(tr("cursor.style"), selection: $model.settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { Text(tr("cursor.style.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(tr("editor.size"), value: $model.settings.cursorScale, range: 0.8...3)
                LabeledSlider(tr("editor.smoothing"), value: $model.settings.cursorSmoothing, range: 0...1)
            }
            Section {
                Toggle(tr("cursor.hide_idle"), isOn: $model.settings.hideIdleCursor)
                Toggle(tr("editor.click_highlights"), isOn: $model.settings.showClickHighlights)
                Toggle(tr("cursor.click_sound"), isOn: $model.settings.clickSound)
            }
        case .camera:
            Section {
                Toggle(tr("editor.show_camera"), isOn: $model.settings.showCamera)
                LabeledSlider(tr("editor.size"), value: $model.settings.cameraSize, range: 0.1...0.5)
                Picker(tr("camera.shape"), selection: $model.settings.cameraShape) {
                    ForEach(CameraShape.allCases) { Image(systemName: $0.icon).help($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                BorderColorRow(color: $model.settings.cameraBorderColor)
                Picker(tr("editor.corner"), selection: $model.settings.cameraCorner) {
                    ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(tr("editor.mirror"), isOn: $model.settings.mirrorCamera)
                Toggle(tr("camera.blur_background"), isOn: $model.settings.cameraBlurBackground)
            }
            Section {
                Text(tr("camera.layout_hint")).font(.caption).foregroundStyle(.secondary)
            }
        case .zoom:
            Section {
                LabeledSlider(tr("editor.auto_level"), value: $model.settings.autoZoomScale, range: 1.2...3)
                Button(tr("editor.regenerate", model.cursor.clicks.count)) { model.regenerateAutoZoom() }
                Text(tr("editor.zoom.select_hint")).font(.caption).foregroundStyle(.secondary)
            }
        case .keys:
            Section {
                Toggle(tr("keys.show"), isOn: $model.settings.showKeystrokes)
                Text(model.keystrokes.isEmpty ? tr("keys.none") : tr("keys.count", model.keystrokes.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .audio:
            Section {
                LabeledSlider("\(tr("audio.volume")) \(Int(model.settings.recordingVolume * 100))%", value: $model.settings.recordingVolume, range: 0...2)
                Toggle(tr("audio.normalize"), isOn: $model.settings.normalizeAudio)
                Toggle(tr("audio.noise"), isOn: $model.settings.noiseReduction)
                    .help(tr("audio.noise_hint"))
            }
            Section {
                HStack {
                    Text(model.settings.musicFile == nil ? tr("audio.no_music") : tr("audio.music"))
                    Spacer()
                    Button(model.settings.musicFile == nil ? tr("audio.choose_music") : tr("audio.change")) { model.chooseMusic() }
                    if model.settings.musicFile != nil {
                        Button { model.settings.musicFile = nil } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if model.settings.musicFile != nil {
                    LabeledSlider("\(tr("audio.music_volume")) \(Int(model.settings.musicVolume * 100))%", value: $model.settings.musicVolume, range: 0...1)
                }
            }
        case .titles:
            Section { TitleCardEditor(title: tr("titles.intro"), card: $model.settings.intro) }
            Section { TitleCardEditor(title: tr("titles.outro"), card: $model.settings.outro) }
        case .trim:
            if model.duration > 0 {
                Section(tr("editor.trim")) {
                    LabeledSlider("\(tr("editor.start")) \(formatTime(model.settings.trimStart))", value: $model.settings.trimStart, range: 0...model.duration)
                    LabeledSlider(
                        "\(tr("editor.end")) \(formatTime(model.trimEnd))",
                        value: Binding(
                            get: { model.trimEnd },
                            set: { model.settings.trimEnd = max($0, model.settings.trimStart + 0.5) }
                        ),
                        range: 0...model.duration
                    )
                }
            }
            if !model.flags.isEmpty {
                Section(tr("editor.flags")) {
                    ForEach(Array(model.flags.enumerated()), id: \.offset) { index, time in
                        Button {
                            model.seek(to: time)
                        } label: {
                            Label("\(index + 1). \(formatTime(time))", systemImage: "flag.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct TitleCardEditor: View {
    let title: String
    @Binding var card: TitleCard

    var body: some View {
        Toggle(title, isOn: $card.enabled)
        if card.enabled {
            TextField(tr("titles.heading"), text: $card.title)
            TextField(tr("titles.subtitle"), text: $card.subtitle)
            LabeledSlider("\(tr("titles.duration")) \(String(format: "%.1f", card.duration)) s", value: $card.duration, range: 1...6)
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Inspectors

/// Header shared by inspectors: time range, jump and delete.
private struct SpanHeader: View {
    @ObservedObject var model: EditorModel
    let selection: EditorSelection
    let start: Double
    let end: Double

    var body: some View {
        HStack {
            Text("\(formatTime(start)) – \(formatTime(end))").font(.system(.callout, design: .monospaced))
            Spacer()
            Button { model.seek(to: start) } label: { Image(systemName: "arrow.right.circle") }
                .buttonStyle(.borderless)
                .help(tr("zoom.go"))
            Button(role: .destructive) { model.delete(selection) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(tr("delete"))
        }
    }
}

private struct ZoomInspector: View {
    @ObservedObject var model: EditorModel
    let segment: ZoomSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("", isOn: Binding(get: { segment.isEnabled }, set: { value in model.updateZoom(segment.id) { $0.isEnabled = value } }))
                    .labelsHidden()
                    .help(tr("zoom.enabled"))
                Label(tr("editor.zoom"), systemImage: "plus.magnifyingglass").font(.headline)
            }
            SpanHeader(model: model, selection: .zoom(segment.id), start: segment.start, end: segment.end)
            LabeledSlider(
                "\(tr("zoom.level")) \(String(format: "%.1f", segment.scale))×",
                value: Binding(get: { segment.scale }, set: { value in model.updateZoom(segment.id) { $0.scale = value } }),
                range: 1.1...4
            )
            Picker(tr("zoom.style"), selection: Binding(get: { segment.resolvedStyle }, set: { value in model.updateZoom(segment.id) { $0.style = value == .classic ? nil : value } })) {
                ForEach(ZoomStyle.allCases) { Text(tr("zoom.style.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(tr("zoom.focus"), selection: Binding(
                get: { segment.focus == nil },
                set: { follow in
                    let start = model.cursorPosition(at: (segment.start + segment.end) / 2)
                    model.updateZoom(segment.id) { $0.focus = follow ? nil : start }
                }
            )) {
                Text(tr("zoom.follow")).tag(true)
                Text(tr("zoom.fixed")).tag(false)
            }
            .pickerStyle(.segmented)
            if let focus = segment.focus {
                FramePreview(model: model, time: (segment.start + segment.end) / 2) { size in
                    let center = ZoomTimeline.clampedCenter(focus, scale: segment.scale)
                    let box = CGSize(width: size.width / segment.scale, height: size.height / segment.scale)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 2)
                            .background(Color.white.opacity(0.08))
                            .frame(width: box.width, height: box.height)
                            .offset(x: center.x * size.width - box.width / 2, y: center.y * size.height - box.height / 2)
                        Image(systemName: "scope")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .position(x: focus.x * size.width, y: focus.y * size.height)
                    }
                } onDrag: { start, current in
                    model.updateZoom(segment.id) { $0.focus = current }
                    _ = start
                }
                Text(tr("zoom.focus_hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EditInspector: View {
    @ObservedObject var model: EditorModel
    let edit: TimeEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(edit.isCut ? tr("edit.cut") : tr("edit.speed"), systemImage: edit.isCut ? "scissors" : "hare").font(.headline)
            SpanHeader(model: model, selection: .edit(edit.id), start: edit.start, end: edit.end)
            Picker(tr("edit.action"), selection: Binding(get: { edit.speed }, set: { value in model.updateEdit(edit.id) { $0.speed = value } })) {
                Text(tr("edit.remove")).tag(0.0)
                ForEach(TimeEdit.speeds, id: \.self) { speed in
                    Text(speed == speed.rounded() ? "\(Int(speed))×" : "\(String(format: "%.1f", speed))×").tag(speed)
                }
            }
            .pickerStyle(.segmented)
            Text(edit.isCut ? tr("edit.cut_hint") : tr("edit.speed_hint", formatTime((edit.end - edit.start) / max(edit.speed, 0.01))))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct CameraLayoutInspector: View {
    @ObservedObject var model: EditorModel
    let segment: CameraLayoutSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("editor.camera"), systemImage: "person.crop.square").font(.headline)
            SpanHeader(model: model, selection: .camera(segment.id), start: segment.start, end: segment.end)
            Picker(tr("camera.layout"), selection: Binding(get: { segment.layout }, set: { value in model.updateCameraLayout(segment.id) { $0.layout = value } })) {
                ForEach(CameraLayout.allCases) { Text(tr("camera.layout.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }
}

private struct AnnotationInspector: View {
    @ObservedObject var model: EditorModel
    let annotation: Annotation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(tr("annotation.kind"), selection: Binding(get: { annotation.kind }, set: { value in model.updateAnnotation(annotation.id) { $0.kind = value } })) {
                ForEach(AnnotationKind.allCases) { kind in
                    Image(systemName: kind.icon).help(tr("annotation.kind.\(kind.rawValue)")).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Text(tr("annotation.kind.\(annotation.kind.rawValue)")).font(.headline)
            SpanHeader(model: model, selection: .annotation(annotation.id), start: annotation.start, end: annotation.end)
            if annotation.kind == .text {
                TextField(tr("annotation.text"), text: Binding(get: { annotation.text }, set: { value in model.updateAnnotation(annotation.id) { $0.text = value } }), axis: .vertical)
                    .lineLimit(1...4)
            }
            if annotation.kind == .text || annotation.kind == .arrow || annotation.kind == .box {
                ColorPicker(tr("annotation.color"), selection: Binding(
                    get: { annotation.color.color },
                    set: { value in model.updateAnnotation(annotation.id) { $0.color = RGBAColor(value) } }
                ), supportsOpacity: false)
                LabeledSlider(tr("editor.size"), value: Binding(get: { annotation.size }, set: { value in model.updateAnnotation(annotation.id) { $0.size = value } }), range: 0.4...3)
            }
            FramePreview(model: model, time: (annotation.start + annotation.end) / 2) { size in
                AnnotationShape(annotation: annotation, size: size)
            } onDrag: { start, current in
                model.updateAnnotation(annotation.id) { item in
                    switch item.kind {
                    case .arrow:
                        item.from = start
                        item.to = current
                    case .text:
                        item.rect.origin = CGPoint(x: current.x - item.rect.width / 2, y: current.y - item.rect.height / 2)
                    case .box, .spotlight, .blur:
                        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
                        if rect.width > 0.01, rect.height > 0.01 { item.rect = rect }
                    }
                }
            }
            Text(tr("annotation.position_hint.\(annotation.kind.rawValue)")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Preview of an annotation on the frame editor.
private struct AnnotationShape: View {
    let annotation: Annotation
    let size: CGSize

    var body: some View {
        let rect = CGRect(x: annotation.rect.minX * size.width, y: annotation.rect.minY * size.height,
                          width: annotation.rect.width * size.width, height: annotation.rect.height * size.height)
        ZStack(alignment: .topLeading) {
            switch annotation.kind {
            case .arrow:
                Path { path in
                    path.move(to: CGPoint(x: annotation.from.x * size.width, y: annotation.from.y * size.height))
                    path.addLine(to: CGPoint(x: annotation.to.x * size.width, y: annotation.to.y * size.height))
                }
                .stroke(annotation.color.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle().fill(annotation.color.color).frame(width: 9, height: 9)
                    .position(x: annotation.to.x * size.width, y: annotation.to.y * size.height)
            case .text:
                Text(annotation.text.isEmpty ? "…" : annotation.text)
                    .font(.system(size: max(9, size.height * 0.045 * annotation.size), weight: .bold))
                    .foregroundStyle(annotation.color.color)
                    .padding(4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .position(x: rect.midX, y: rect.midY)
            case .box:
                RoundedRectangle(cornerRadius: 4).strokeBorder(annotation.color.color, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
            case .spotlight:
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            case .blur:
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Rectangle().strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Raw recording frame at `time`; drag on it to edit positions (normalized, origin top-left).
private struct FramePreview<Overlay: View>: View {
    @ObservedObject var model: EditorModel
    let time: Double
    @ViewBuilder let overlay: (CGSize) -> Overlay
    let onDrag: (CGPoint, CGPoint) -> Void
    @State private var image: NSImage?

    var body: some View {
        let aspect = model.sourceSize.height > 0 ? model.sourceSize.width / model.sourceSize.height : 16 / 9
        Color.black
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            }
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    overlay(size)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            func normalized(_ point: CGPoint) -> CGPoint {
                                CGPoint(x: min(max(point.x / max(size.width, 1), 0), 1), y: min(max(point.y / max(size.height, 1), 0), 1))
                            }
                            onDrag(normalized(value.startLocation), normalized(value.location))
                        })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: Int(time * 10)) {
                image = await model.framePreview(at: time)
            }
    }
}

// MARK: - Timeline

private struct LaneItem: Identifiable {
    let selection: EditorSelection
    let start: Double
    let end: Double
    let label: String
    let icon: String?
    let color: Color
    var id: UUID { selection.id }
}

/// Horizontally scrollable timeline; `zoom` stretches it beyond the visible width.
private struct TimelineArea: View {
    @ObservedObject var model: EditorModel
    let zoom: Double

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                TimelineStrip(model: model)
                    .frame(width: max(geometry.size.width - 28, 100) * zoom)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 10)
    }
}

/// Ruler with time labels, clip track with the audio waveform, then one lane per kind of edit.
/// Click to select, drag to move, drag the edges to resize, double-click an empty spot to add.
private struct TimelineStrip: View {
    @ObservedObject var model: EditorModel

    private let rulerHeight: CGFloat = 26
    private let clipHeight: CGFloat = 40
    private let laneHeight: CGFloat = 26
    private let gap: CGFloat = 5

    private var lanes: [(title: String, items: [LaneItem], lane: EditorLane)] {
        let settings = model.settings
        let violet = EditorStyle.accent
        var result: [(String, [LaneItem], EditorLane)] = [
            (tr("lane.zoom"), settings.zoomSegments.map { segment in
                LaneItem(selection: .zoom(segment.id), start: segment.start, end: segment.end,
                         label: "\(String(format: "%.1f×", segment.scale)) · \(segment.resolvedStyle == .loupe ? tr("zoom.style.loupe") : (segment.focus == nil ? tr("zoom.auto") : tr("zoom.fixed")))",
                         icon: "plus.magnifyingglass", color: segment.isEnabled ? violet : .gray)
            }, .zoom),
            (tr("lane.edits"), settings.timeEdits.map { edit in
                LaneItem(selection: .edit(edit.id), start: edit.start, end: edit.end,
                         label: edit.isCut ? tr("edit.cut") : "\(String(format: "%g", edit.speed))×",
                         icon: edit.isCut ? "scissors" : "hare", color: edit.isCut ? .red : .orange)
            }, .edits),
        ]
        if model.hasCamera {
            result.append((tr("lane.camera"), settings.cameraLayouts.map { segment in
                LaneItem(selection: .camera(segment.id), start: segment.start, end: segment.end,
                         label: tr("camera.layout.\(segment.layout.rawValue)"), icon: "person.crop.square", color: .teal)
            }, .camera))
        }
        result.append((tr("lane.annotations"), settings.annotations.map { annotation in
            LaneItem(selection: .annotation(annotation.id), start: annotation.start, end: annotation.end,
                     label: annotation.kind == .text ? annotation.text : tr("annotation.kind.\(annotation.kind.rawValue)"),
                     icon: annotation.kind.icon, color: .pink)
        }, .annotations))
        return result
    }

    var body: some View {
        let lanes = lanes
        let lanesTop = rulerHeight + gap + clipHeight + gap
        let totalHeight = lanesTop + CGFloat(lanes.count) * (laneHeight + gap)
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(model.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / duration) * width }
            let seconds = { (points: CGFloat) in Double(points / width) * duration }

            ZStack(alignment: .topLeading) {
                ruler(width: width, duration: duration, x: x, seconds: seconds)
                clipTrack(width: width, x: x, seconds: seconds)
                    .offset(y: rulerHeight + gap)
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    SpanLane(model: model, title: lane.title, items: lane.items, lane: lane.lane, width: width, height: laneHeight, x: x, seconds: seconds)
                        .offset(y: lanesTop + CGFloat(index) * (laneHeight + gap))
                }
                // Cuts and trimmed-out parts are shaded across all tracks.
                ForEach(model.settings.timeEdits.filter(\.isCut)) { edit in
                    Rectangle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: max(1, x(edit.end) - x(edit.start)), height: totalHeight - rulerHeight)
                        .offset(x: x(edit.start), y: rulerHeight)
                        .allowsHitTesting(false)
                }
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: x(model.settings.trimStart), height: totalHeight - rulerHeight)
                    .offset(y: rulerHeight)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, width - x(model.trimEnd)), height: totalHeight - rulerHeight)
                    .offset(x: x(model.trimEnd), y: rulerHeight)
                    .allowsHitTesting(false)
                // Playhead with knob.
                ZStack(alignment: .top) {
                    Rectangle().fill(EditorStyle.accent).frame(width: 2, height: totalHeight)
                    Circle().fill(EditorStyle.accent).frame(width: 12, height: 12).offset(y: 2)
                }
                .offset(x: x(model.currentTime) - 6)
                .frame(width: 12)
                .allowsHitTesting(false)
            }
        }
        .frame(height: totalHeight)
    }

    private func ruler(width: CGFloat, duration: Double, x: @escaping (Double) -> CGFloat, seconds: @escaping (CGFloat) -> Double) -> some View {
        // Pick a label step that keeps labels ~90 pt apart.
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { x($0) - x(0) >= 90 } ?? 600
        let marks = Array(stride(from: 0.0, through: duration, by: step))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks, id: \.self) { mark in
                VStack(spacing: 3) {
                    Text(Self.label(mark)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3, height: 3)
                }
                .fixedSize()
                .offset(x: x(mark) - 14)
            }
            ForEach(model.flags.indices, id: \.self) { index in
                Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.yellow)
                    .offset(x: x(model.flags[index]) - 2, y: 14)
            }
        }
        .frame(width: width, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            model.seek(to: seconds(value.location.x))
        })
        .help(tr("editor.timeline.ruler_hint"))
    }

    /// The recording as one clip: audio waveform, click marks, length and speed.
    private func clipTrack(width: CGFloat, x: @escaping (Double) -> CGFloat, seconds: @escaping (CGFloat) -> Double) -> some View {
        let waveform = model.waveform
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.86, green: 0.6, blue: 0.16).opacity(0.9))
            if !waveform.isEmpty {
                Path { path in
                    let mid = clipHeight / 2
                    let step = width / CGFloat(waveform.count)
                    path.move(to: CGPoint(x: 0, y: mid))
                    for (index, value) in waveform.enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(index) * step, y: mid - CGFloat(value) * mid * 0.85))
                    }
                    for (index, value) in waveform.enumerated().reversed() {
                        path.addLine(to: CGPoint(x: CGFloat(index) * step, y: mid + CGFloat(value) * mid * 0.85))
                    }
                    path.closeSubpath()
                }
                .fill(Color.black.opacity(0.22))
            }
            ForEach(model.cursor.clicks.indices, id: \.self) { index in
                Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: 8)
                    .offset(x: x(model.cursor.clicks[index].t), y: 3)
            }
            Text("\(tr("timeline.clip")) · \(formatClock(model.finalDuration)) · \(String(format: "%g", model.playbackRate))×")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.trailing, 10)
                .frame(width: width, height: clipHeight, alignment: .trailing)
        }
        .frame(width: width, height: clipHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            model.selection = nil
            model.seek(to: seconds(location.x))
        }
    }

    private static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return seconds < 1 && seconds > 0 ? String(format: "%.1f", seconds) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SpanLane: View {
    @ObservedObject var model: EditorModel
    let title: String
    let items: [LaneItem]
    let lane: EditorLane
    let width: CGFloat
    let height: CGFloat
    let x: (Double) -> CGFloat
    let seconds: (CGFloat) -> Double
    @State private var dragOrigin: (id: UUID, start: Double, end: Double)?
    @State private var hoverTime: Double?
    @State private var menuItem: UUID?

    var body: some View {
        let ghost = hoverTime.flatMap { model.freeSlot(in: lane, at: $0) }
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
                .overlay(alignment: .leading) {
                    if items.isEmpty, ghost == nil {
                        Text(title).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 8).allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase { hoverTime = seconds(point.x) } else { hoverTime = nil }
                }
                .onTapGesture(coordinateSpace: .local) { location in
                    let time = seconds(location.x)
                    if model.freeSlot(in: lane, at: time) != nil {
                        model.add(in: lane, at: time)
                    } else {
                        model.selection = nil
                        model.seek(to: time)
                    }
                }
                .help(tr("timeline.lane_hint", title))

            // "+" preview of what a click would add.
            if let ghost {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [EditorStyle.accent.opacity(0.55), EditorStyle.accent.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(EditorStyle.accent.opacity(0.8), lineWidth: 1))
                    .overlay(Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(.white))
                    .frame(width: max(8, x(ghost.end) - x(ghost.start)), height: height)
                    .offset(x: x(ghost.start))
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                block(item).offset(x: x(item.start))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func block(_ item: LaneItem) -> some View {
        let selected = model.selection == item.selection
        let blockWidth = max(6, x(item.end) - x(item.start))
        return RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [item.color.opacity(selected ? 1 : 0.85), item.color.opacity(selected ? 0.85 : 0.65)], startPoint: .top, endPoint: .bottom))
            .overlay {
                if blockWidth > 34 {
                    HStack(spacing: 4) {
                        if let icon = item.icon { Image(systemName: icon).font(.caption2) }
                        Text(item.label).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { edgeHandle(item, edge: .start, selected: selected) }
            .overlay(alignment: .trailing) { edgeHandle(item, edge: .end, selected: selected) }
            .frame(width: blockWidth, height: height)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = item.selection }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let origin = origin(for: item)
                        model.selection = item.selection
                        model.move(item.selection, to: origin.start + seconds(value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .overlay(RightClickCatcher {
                model.selection = item.selection
                menuItem = item.id
            })
            .popover(isPresented: Binding(get: { menuItem == item.id }, set: { if !$0 { menuItem = nil } }), arrowEdge: .top) {
                ItemMenu(model: model, item: item.selection) { menuItem = nil }
            }
            .help(tr("timeline.block_hint"))
    }

    private func edgeHandle(_ item: LaneItem, edge: SpanEditing.Edge, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(selected ? 0.85 : 0.001))
            .frame(width: 4)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = origin(for: item)
                        model.selection = item.selection
                        let base = edge == .start ? origin.start : origin.end
                        model.resize(item.selection, edge: edge, to: base + seconds(value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

    /// Item bounds when the current drag began (translations are relative to them).
    private func origin(for item: LaneItem) -> (start: Double, end: Double) {
        if let dragOrigin, dragOrigin.id == item.id { return (dragOrigin.start, dragOrigin.end) }
        dragOrigin = (item.id, item.start, item.end)
        return (item.start, item.end)
    }
}

/// Catches right clicks only; every other mouse event passes through to SwiftUI.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            let type = NSApp.currentEvent?.type
            return type == .rightMouseDown || type == .rightMouseUp ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}

/// Right-click panel for a timeline item.
private struct ItemMenu: View {
    @ObservedObject var model: EditorModel
    let item: EditorSelection
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .zoom(let id) = item, let zoom = model.settings.zoomSegments.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                    ForEach(ZoomStyle.allCases) { style in
                        Button {
                            model.updateZoom(id) { $0.style = style == .classic ? nil : style }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: style.icon).font(.title3)
                                Text(tr("zoom.style.\(style.rawValue)")).font(.callout)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(zoom.resolvedStyle == style ? EditorStyle.accent.opacity(0.25) : .clear))
                            .foregroundStyle(zoom.resolvedStyle == style ? EditorStyle.accent : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("zoom.level"))
                        Spacer()
                        Text("\(Int((zoom.scale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(get: { zoom.scale }, set: { value in model.updateZoom(id) { $0.scale = value } }), in: 1.1...4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                MenuRow(icon: "plus.square.on.square", title: tr("item.apply_all")) { model.applyZoomLevelToAll(from: id) }
                Divider().padding(.vertical, 4)
            }
            MenuRow(icon: "scissors", title: tr("item.split"), shortcut: "C") { model.split(item); close() }
            MenuRow(icon: "plus", title: tr("item.duplicate"), shortcut: "⌘D") { model.duplicate(item); close() }
            if case .zoom(let id) = item {
                let enabled = model.settings.zoomSegments.first { $0.id == id }?.isEnabled ?? true
                MenuRow(icon: enabled ? "nosign" : "checkmark.circle", title: enabled ? tr("item.disable") : tr("item.enable"), shortcut: "D") {
                    model.toggleEnabled(item)
                }
            }
            Divider().padding(.vertical, 4)
            MenuRow(icon: "doc.on.doc", title: tr("item.copy"), shortcut: "⌘C") { model.copy(item); close() }
            MenuRow(icon: "scissors.badge.ellipsis", title: tr("item.cut"), shortcut: "⌘X") { model.cut(item); close() }
            Divider().padding(.vertical, 4)
            MenuRow(icon: "trash", title: tr("item.remove"), shortcut: "⌫", destructive: true) { model.delete(item); close() }
        }
        .padding(.vertical, 10)
        .frame(width: 300)
        .environment(\.colorScheme, .dark)
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

/// Camera border: quick swatches (the last one removes the border) plus a full color picker.
private struct BorderColorRow: View {
    @Binding var color: RGBAColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("camera.border_color"))
            HStack(spacing: 6) {
                ForEach(RGBAColor.borderPresets, id: \.key) { preset in
                    swatch(preset.color, key: preset.key)
                }
                ColorPicker("", selection: Binding(
                    get: { color.color },
                    set: { color = RGBAColor($0) }
                ), supportsOpacity: true)
                .labelsHidden()
                .help(tr("camera.border.custom"))
            }
        }
    }

    private func swatch(_ value: RGBAColor, key: String) -> some View {
        let selected = value == color
        return ZStack {
            Circle().fill(value.a == 0 ? Color.clear : value.color)
            if value.a == 0 {
                Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().strokeBorder(selected ? EditorStyle.accent : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(Circle())
        .help(tr("camera.border.\(key)"))
        .onTapGesture { color = value }
    }
}
