import AppKit
import MusicLibraryCore
import SwiftUI

/// Digitize Vinyl (sidebar ▸ Import): pick one of your records, record it from an input, cut the recording into
/// its tracks on the waveform and save them as FLAC. Until a record is in the collection it points to adding one.
struct VinylDigitizeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let vinyl = model.vinyl!
        let records = model.collection.items(in: .vinyl).filter(\.isEditable)
        Group {
            if vinyl.isOpening {
                ProgressView("Opening the recording…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = vinyl.item {
                VinylSessionPage(vinyl: vinyl, item: item)
            } else if records.isEmpty {
                ContentUnavailableView {
                    Label("Add a Record First", systemImage: "record.circle")
                } description: {
                    Text("Digitizing records a record you own. Add it to your Physical Collection, then come back here to record it.")
                } actions: {
                    Button("Add a Record…") { model.collectionSheet = .add(medium: .vinyl, prefill: nil) }
                        .buttonStyle(.borderedProminent)
                    Button("Go to Vinyl") { model.sidebar = .collection(.vinyl) }
                }
            } else {
                VinylRecordPicker(records: records, vinyl: vinyl)
            }
        }
        .navigationTitle("Digitize Vinyl")
        .onAppear { vinyl.refreshDevices() }
        .alert("Discard the Recording?", isPresented: Binding(get: { vinyl.pendingItemID != nil }, set: { if !$0 { vinyl.pendingItemID = nil } })) {
            Button("Discard and Switch", role: .destructive) { vinyl.confirmSwitch() }
            Button("Keep It", role: .cancel) { vinyl.pendingItemID = nil }
        } message: {
            Text("The recording of “\(vinyl.session.flatMap { model.item(id: $0.itemID)?.album } ?? "another record")” has tracks that aren't saved yet. One record is digitized at a time.")
        }
    }
}

/// The records you can digitize, the ones not digitized yet first.
private struct VinylRecordPicker: View {
    @Environment(AppModel.self) private var model
    let records: [CollectionItem]
    let vinyl: VinylController

    var body: some View {
        let sorted = records.sorted { a, b in
            let da = model.collection.digitalState(a).needsDigitizing, db = model.collection.digitalState(b).needsDigitizing
            if da != db { return da }
            return (a.stickerNumber ?? .max, a.album) < (b.stickerNumber ?? .max, b.album)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Choose a Record")
                    Spacer()
                    Button("Add a Record…") { model.collectionSheet = .add(medium: .vinyl, prefill: nil) }
                }
                Text("Record it from your turntable's preamp or audio interface, then cut it into tracks. You can save a few tracks now and the rest another time.")
                    .font(.callout).foregroundStyle(.subtext)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], alignment: .leading, spacing: 20) {
                    ForEach(sorted) { item in
                        Button { vinyl.choose(item.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 150,
                                        revision: model.coverRevision, title: item.album)
                                Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.callout.weight(.medium)).lineLimit(1)
                                Text(item.artist).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                                Text(VinylText.state(model.collection.digitalState(item))).font(.caption2).foregroundStyle(.subtext)
                            }
                            .frame(width: 150, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
    }
}

enum VinylText {
    static func state(_ state: DigitalState) -> String {
        switch state {
        case .none: "Not digitized yet"
        case .digitized(let n): "Digitized · \(n) \(n == 1 ? "song" : "songs")"
        case .partial(let have, let of): "\(have) of \(of) songs digitized"
        case .otherCopy: "Same album in your digital collection"
        case .missing: "Its digital copy is gone"
        }
    }

    /// "3:07.4", "1:02:03.5".
    static func time(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let tenths = Int((s * 10).rounded(.down))
        let h = tenths / 36_000, m = (tenths / 600) % 60, sec = (tenths / 10) % 60, t = tenths % 10
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, sec, t) : String(format: "%d:%02d.%d", m, sec, t)
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

private struct VinylSessionPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let vinyl: VinylController
    let item: CollectionItem
    @State private var confirmDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let message = vinyl.message {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(message).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { vinyl.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
                }
                HStack(alignment: .top, spacing: 20) {
                    card("Input") { VinylInputPanel(vinyl: vinyl) }
                    card("Recording") { VinylRecordPanel(vinyl: vinyl) }
                }
                if vinyl.session != nil, vinyl.frameCount > 0 {
                    card("Tracks") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Click the waveform to move the playhead and press Space to listen. Drag a cut's edge to move it, or drag elsewhere to scroll; ⌘-scroll or pinch to zoom.")
                                .font(.caption).foregroundStyle(.subtext)
                            VinylWaveformEditor(vinyl: vinyl)
                            VinylCutList(vinyl: vinyl, item: item)
                        }
                    }
                    saveBar
                }
            }
            .padding(24)
        }
        .onChange(of: item.releaseID) { vinyl.reloadRelease() }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) { vinyl.discard() }
        } message: {
            Text("Tracks already saved stay in your digital collection.")
        }
    }

    private var header: some View {
        let records = model.collection.items(in: .vinyl).filter(\.isEditable)
        return HStack(alignment: .center, spacing: 16) {
            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 96,
                    revision: model.coverRevision, title: item.album)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.title2.bold()).lineLimit(2)
                Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.title3).foregroundStyle(.subtext)
                HStack(spacing: 8) {
                    if let sticker = item.sticker { StickerPill(sticker: sticker) }
                    Text(VinylText.state(model.collection.digitalState(item))).font(.callout).foregroundStyle(.subtext)
                }
            }
            Spacer()
            Menu("Change Record") {
                ForEach(records) { r in
                    Button { vinyl.choose(r.id) } label: {
                        Text([r.sticker?.text, r.album, r.artist].compactMap { $0 }.joined(separator: " · "))
                    }
                    .disabled(r.id == item.id)
                }
            }
            .fixedSize()
            .disabled(vinyl.isBusy)
            Button("Open Record") { model.showItem(id: item.id) }
        }
    }

    private var saveBar: some View {
        let count = vinyl.cutsToSave.count
        return HStack(spacing: 12) {
            if vinyl.isSaving {
                ProgressView().controlSize(.small)
                Text(vinyl.statusLine).font(.callout)
                Button("Stop") { vinyl.cancelSave() }
            } else {
                Button { vinyl.save() } label: {
                    Label(count == 0 ? "Save to Digital Collection" : "Save \(count) \(count == 1 ? "Track" : "Tracks") to Digital Collection",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(count == 0 || vinyl.state == .recording || vinyl.state == .paused)
                .help("Saves each named cut as a FLAC file in your library, like a ripped CD")
                if !vinyl.statusLine.isEmpty { Text(vinyl.statusLine).font(.callout).foregroundStyle(.subtext) }
            }
            Spacer()
            Button("Discard Recording…", role: .destructive) { confirmDiscard = true }
                .disabled(vinyl.isBusy)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: Input

private struct VinylInputPanel: View {
    @Bindable var vinyl: VinylController

    var body: some View {
        let locked = vinyl.session != nil
        let running = vinyl.state != .idle
        VStack(alignment: .leading, spacing: 12) {
            if vinyl.devices.isEmpty {
                HStack {
                    Text("No input found. Connect your turntable, phono preamp or audio interface.").font(.callout)
                    Button("Look Again") { vinyl.refreshDevices() }
                }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Input").foregroundStyle(.subtext)
                        HStack {
                            Picker("Input", selection: $vinyl.deviceUID) {
                                ForEach(vinyl.devices) { d in
                                    Text(d.channels == 1 ? "\(d.name) (mono)" : d.name).tag(Optional(d.uid))
                                }
                            }
                            .labelsHidden()
                            .disabled(running)
                            Button { vinyl.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).disabled(running)
                                .help("Look for inputs again")
                        }
                    }
                    GridRow {
                        Text("Sample rate").foregroundStyle(.subtext)
                        Picker("Sample rate", selection: $vinyl.sampleRate) {
                            ForEach(rates, id: \.self) { Text("\(AudioFormat.kHzString(Double($0))) kHz").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(running || locked)
                    }
                    GridRow {
                        Text("Bit depth").foregroundStyle(.subtext)
                        Picker("Bit depth", selection: $vinyl.bitDepth) {
                            ForEach(VinylFormat.bitDepths, id: \.self) { Text("\($0)-bit").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(running || locked)
                    }
                }
                if let session = vinyl.session {
                    Text("This recording is \(session.format.summary)\(session.format.channels == 1 ? ", mono" : ""), saved as FLAC. Discard it to record at another rate or depth.")
                        .font(.caption).foregroundStyle(.subtext)
                } else {
                    Text("Saved as lossless FLAC. 24-bit / 96 kHz takes about \(VinylText.size(VinylFormat(sampleRate: 96_000, bitDepth: 24, channels: 2).bytesPerMinute)) a minute while recording.")
                        .font(.caption).foregroundStyle(.subtext)
                }
            }
            VinylMeter(levels: vinyl.levels, clipped: vinyl.clipped, active: vinyl.state != .idle) { vinyl.resetClip() }
            HStack(spacing: 14) {
                Button(vinyl.state == .monitoring ? "Stop Checking" : "Check Levels") { vinyl.toggleMonitoring() }
                    .disabled(vinyl.state == .recording || vinyl.state == .paused || vinyl.device == nil)
                    .help("Shows the input's level without recording: the loudest parts should stay out of the red")
                Toggle("Listen", isOn: $vinyl.listen)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Plays the input through \(vinyl.outputName) while checking levels or recording, a moment behind. It doesn't change what's recorded. With a microphone, use headphones.")
                if vinyl.listen {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.subtext)
                    Slider(value: $vinyl.listenVolume, in: 0...1).frame(width: 110)
                        .help("Listening volume (the recording's level isn't changed)")
                }
            }
            if let note = vinyl.inputNote { Text(note).font(.caption).foregroundStyle(.subtext) }
            if vinyl.microphoneDenied {
                HStack(alignment: .firstTextBaseline) {
                    Text("Music Library isn't allowed to record. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.").font(.callout)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var rates: [Int] {
        var r = vinyl.device?.sampleRates ?? []
        if r.isEmpty { r = [44_100, 48_000, 88_200, 96_000] }
        if !r.contains(vinyl.sampleRate) { r.append(vinyl.sampleRate) }
        return r.sorted()
    }
}

/// Left and right peak levels in dB, green to red at the top, with a clip light that stays on until clicked.
private struct VinylMeter: View {
    @Environment(\.theme) private var theme
    let levels: [Float]
    let clipped: Bool
    let active: Bool
    let resetClip: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                bar(levels.first ?? 0, "L")
                bar(levels.count > 1 ? levels[1] : 0, "R")
            }
            Button(action: resetClip) {
                Text("CLIP").font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(clipped ? Color.red : theme.fill))
                    .foregroundStyle(clipped ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(clipped ? "The input reached full scale: turn the level down a little. Click to reset." : "Lights when the input reaches full scale")
        }
        .opacity(active ? 1 : 0.5)
    }

    private func bar(_ level: Float, _ label: String) -> some View {
        let db = 20 * log10(Double(max(level, 1e-5)))
        let fraction = max(0, min(1, (db + 60) / 60))
        return HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(.subtext)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(theme.fill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * fraction) }
                }
            }
            .frame(height: 8)
            Text(level > 0.00001 ? String(format: "%.0f dB", db) : "–∞ dB").font(.caption2.monospacedDigit()).foregroundStyle(.subtext)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: Recording

private struct VinylRecordPanel: View {
    let vinyl: VinylController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                switch vinyl.state {
                case .recording:
                    Button { vinyl.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { vinyl.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                case .paused:
                    Button { vinyl.record() } label: { Label("Resume", systemImage: "record.circle") }.buttonStyle(.borderedProminent).tint(.red)
                    Button { vinyl.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                case .idle, .monitoring:
                    Button { vinyl.record() } label: {
                        Label(vinyl.session == nil ? "Record" : "Record More", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(vinyl.device == nil || vinyl.isSaving || vinyl.microphoneDenied)
                    .help(vinyl.session == nil ? "Starts recording from the input" : "Records more at the end of this recording, with a cut where it starts")
                }
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                if vinyl.state == .recording {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                        .phaseAnimator([1.0, 0.3]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.8) }
                }
                Text(VinylText.time(vinyl.duration)).font(.system(.title2, design: .monospaced).weight(.medium))
                if let format = vinyl.session?.format {
                    Text("· \(VinylText.size(vinyl.frameCount * format.bytesPerFrame))").font(.callout).foregroundStyle(.subtext)
                }
            }
            Text(hint).font(.caption).foregroundStyle(.subtext).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        switch vinyl.state {
        case .recording: "Pause to turn the record over: resuming goes on in the same recording, with a cut between the sides."
        case .paused: "Paused. Turn the record over (or cue the next songs), then Resume."
        case .idle, .monitoring:
            vinyl.session == nil
                ? "Start recording, then put the needle down. The quiet before and after the music is left out of the tracks."
                : "Stopped. Cut the recording into tracks below, or Record More to add to it."
        }
    }
}

// MARK: Waveform

/// The recording's waveform: an overview of all of it with the part shown, and that part, zoomable, with the cuts,
/// pauses and the playhead. Clicking moves the playhead; dragging a cut's edge moves it, elsewhere scrolls.
private struct VinylWaveformEditor: View {
    @Environment(\.theme) private var theme
    let vinyl: VinylController
    /// The part shown, in seconds.
    @State private var visibleStart = 0.0
    @State private var visibleLength = 60.0
    @State private var drag: DragMode?
    @State private var zoomBase: Double?

    private enum DragMode {
        case edge(String, VinylController.Edge)
        case pan(Double)
    }

    var body: some View {
        let duration = max(vinyl.duration, 0.1)
        VStack(alignment: .leading, spacing: 8) {
            controls(duration: duration)
            GeometryReader { geo in
                detail(size: geo.size, duration: duration)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            GeometryReader { geo in
                overview(size: geo.size, duration: duration)
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onChange(of: vinyl.frameCount) { _, _ in
            // While recording, the end stays in view.
            if vinyl.state == .recording { visibleStart = max(0, vinyl.duration - visibleLength * 0.9) }
        }
        .onChange(of: vinyl.playhead) { _, frame in
            // Playing past the right edge turns the page.
            guard vinyl.isPreviewing, let rate = vinyl.session?.format.sampleRate else { return }
            let t = Double(frame) / Double(rate)
            if t > visibleStart + visibleLength || t < visibleStart { visibleStart = max(0, t - visibleLength * 0.1) }
        }
        .onAppear {
            visibleLength = min(max(10, duration), 120)
            if vinyl.state == .recording { visibleStart = max(0, duration - visibleLength * 0.9) }
        }
    }

    private func controls(duration: Double) -> some View {
        let rate = Double(vinyl.session?.format.sampleRate ?? 44_100)
        let selected = vinyl.segments.first { $0.id == vinyl.selectedSegmentID }
        let canEdit = vinyl.state == .idle || vinyl.state == .monitoring
        return HStack(spacing: 10) {
            Button { vinyl.togglePreview() } label: {
                Image(systemName: vinyl.isPreviewing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .disabled(!canEdit)
            .help(vinyl.isPreviewing ? "Pause (Space)" : "Play from the playhead (Space)")
            Text("\(VinylText.time(Double(vinyl.playhead) / rate)) / \(VinylText.time(duration))")
                .font(.callout.monospacedDigit())
            Spacer()
            Button("Split at Playhead") { vinyl.splitAtPlayhead() }
                .disabled(!canEdit)
                .help("Cuts the track at the playhead in two, or starts a new track there")
            Button("Delete Cut") { if let selected { vinyl.deleteSegment(selected.id) } }
                .disabled(!canEdit || selected == nil || selected?.isSaved == true)
            Divider().frame(height: 16)
            Button { zoom(by: 2, around: visibleStart + visibleLength / 2, duration: duration) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { zoom(by: 0.5, around: visibleStart + visibleLength / 2, duration: duration) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button("Fit") { visibleStart = 0; visibleLength = duration }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func zoom(by factor: Double, around t: Double, duration: Double) {
        let newLength = min(max(1, visibleLength * factor), max(duration, 1))
        let fraction = visibleLength > 0 ? (t - visibleStart) / visibleLength : 0.5
        visibleLength = newLength
        visibleStart = min(max(0, t - fraction * newLength), max(0, duration - newLength))
    }

    private func pan(to start: Double, duration: Double) {
        visibleStart = min(max(0, start), max(0, duration - visibleLength))
    }

    // MARK: Detail

    private func detail(size: CGSize, duration: Double) -> some View {
        let rate = Double(vinyl.session?.format.sampleRate ?? 44_100)
        let pointsPerSecond = size.width / visibleLength
        func x(_ frame: Int) -> CGFloat { (Double(frame) / rate - visibleStart) * pointsPerSecond }
        func frame(_ x: CGFloat) -> Int { Int(((Double(x) / pointsPerSecond) + visibleStart) * rate) }
        let segments = vinyl.segments
        let envelope = vinyl.envelope
        let gain = CGFloat(vinyl.waveformGain)
        let pauses = vinyl.session?.pauses ?? []
        let selectedID = vinyl.selectedSegmentID
        let playhead = vinyl.playhead
        let options = vinyl.targetOptions
        let accent = theme.accent, fill = theme.fill
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(fill))
            for (k, seg) in segments.enumerated() {
                let r = CGRect(x: x(seg.start), y: 0, width: max(1, x(seg.end) - x(seg.start)), height: size.height)
                guard r.maxX >= 0, r.minX <= size.width else { continue }
                let color: Color = seg.isSaved ? .green : accent
                ctx.fill(Path(r), with: .color(color.opacity(seg.id == selectedID ? 0.30 : (k.isMultiple(of: 2) ? 0.16 : 0.10))))
                ctx.fill(Path(CGRect(x: r.minX, y: 0, width: 1.5, height: size.height)), with: .color(color.opacity(0.9)))
                ctx.fill(Path(CGRect(x: r.maxX - 1.5, y: 0, width: 1.5, height: size.height)), with: .color(color.opacity(0.9)))
                let name = VinylCutList.name(seg, options: options) ?? "Cut \(k + 1)"
                ctx.draw(Text(name).font(.caption2.weight(.semibold)).foregroundStyle(color),
                         at: CGPoint(x: max(r.minX, 0) + 5, y: 4), anchor: .topLeading)
            }
            // The waveform, one bar per point.
            let mid = size.height / 2
            var bars = Path()
            var px: CGFloat = 0
            while px < size.width {
                let f0 = frame(px), f1 = frame(px + 1)
                if f1 > 0 {
                    let p = min(1, CGFloat(envelope.peak(frames: max(0, f0)..<max(f0 + 1, f1))) * gain)
                    let h = max(0.5, p * (mid - 14))
                    bars.addRect(CGRect(x: px, y: mid - h + 6, width: 1, height: h * 2))
                }
                px += 1
            }
            ctx.fill(bars, with: .color(.primary.opacity(0.65)))
            for p in pauses {
                var line = Path()
                line.move(to: CGPoint(x: x(p), y: 0))
                line.addLine(to: CGPoint(x: x(p), y: size.height))
                ctx.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            let hx = x(playhead)
            ctx.fill(Path(CGRect(x: hx - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
            var tri = Path()
            tri.move(to: CGPoint(x: hx - 5, y: size.height))
            tri.addLine(to: CGPoint(x: hx + 5, y: size.height))
            tri.addLine(to: CGPoint(x: hx, y: size.height - 7))
            ctx.fill(tri, with: .color(.red))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil {
                        drag = edge(near: value.startLocation.x, x: x).map { .edge($0.0, $0.1) } ?? .pan(visibleStart)
                    }
                    switch drag {
                    case .edge(let id, let edge): vinyl.move(id, edge, to: frame(value.location.x))
                    case .pan(let origin): pan(to: origin - Double(value.translation.width) / pointsPerSecond, duration: duration)
                    case nil: break
                    }
                }
                .onEnded { value in
                    defer { drag = nil }
                    if case .edge = drag { vinyl.commitMoves(); return }
                    guard abs(value.translation.width) < 3 else { return }
                    let f = frame(value.location.x)
                    vinyl.seek(to: f)
                    vinyl.selectedSegmentID = vinyl.segment(at: f)?.id
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = zoomBase ?? visibleLength
                    if zoomBase == nil { zoomBase = base }
                    let center = visibleStart + visibleLength / 2
                    let newLength = min(max(1, base / value.magnification), max(duration, 1))
                    visibleLength = newLength
                    visibleStart = min(max(0, center - newLength / 2), max(0, duration - newLength))
                }
                .onEnded { _ in zoomBase = nil }
        )
        .onContinuousHover { phase in
            if case .active(let p) = phase, edge(near: p.x, x: x) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .overlay(ScrollWheelCatcher { event, location in
            let t = visibleStart + Double(location.x) / pointsPerSecond
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                zoom(by: event.scrollingDeltaY > 0 ? 0.85 : 1 / 0.85, around: t, duration: duration)
            } else {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                let points = event.hasPreciseScrollingDeltas ? delta : delta * 12
                pan(to: visibleStart - Double(points) / pointsPerSecond, duration: duration)
            }
        })
    }

    /// The unsaved cut edge within a few points of `px`, if any (the later cut's start when two meet).
    private func edge(near px: CGFloat, x: (Int) -> CGFloat) -> (String, VinylController.Edge)? {
        var best: (String, VinylController.Edge, CGFloat)?
        for seg in vinyl.segments where !seg.isSaved {
            for (edge, f) in [(VinylController.Edge.start, seg.start), (.end, seg.end)] {
                let d = abs(x(f) - px)
                if d <= 6, best == nil || d < best!.2 || (d == best!.2 && edge == .start) { best = (seg.id, edge, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: Overview

    private func overview(size: CGSize, duration: Double) -> some View {
        let rate = Double(vinyl.session?.format.sampleRate ?? 44_100)
        let envelope = vinyl.envelope
        let gain = CGFloat(vinyl.waveformGain)
        let segments = vinyl.segments
        let playhead = vinyl.playhead
        let window = (visibleStart, visibleLength)
        let accent = theme.accent, fill = theme.fill
        return Canvas { ctx, size in
            let perPoint = duration / size.width
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(fill))
            for seg in segments {
                let r = CGRect(x: Double(seg.start) / rate / perPoint, y: 0, width: max(1, Double(seg.end - seg.start) / rate / perPoint), height: size.height)
                ctx.fill(Path(r), with: .color((seg.isSaved ? Color.green : accent).opacity(0.22)))
            }
            var bars = Path()
            let mid = size.height / 2
            var px: CGFloat = 0
            while px < size.width {
                let f0 = Int(Double(px) * perPoint * rate), f1 = Int(Double(px + 1) * perPoint * rate)
                let h = max(0.5, min(1, CGFloat(envelope.peak(frames: f0..<max(f0 + 1, f1))) * gain) * (mid - 2))
                bars.addRect(CGRect(x: px, y: mid - h, width: 1, height: h * 2))
                px += 1
            }
            ctx.fill(bars, with: .color(.primary.opacity(0.45)))
            let w = CGRect(x: window.0 / perPoint, y: 0.5, width: max(4, window.1 / perPoint), height: size.height - 1)
            ctx.stroke(Path(roundedRect: w, cornerRadius: 3), with: .color(accent), lineWidth: 1.5)
            ctx.fill(Path(CGRect(x: Double(playhead) / rate / perPoint - 0.5, y: 0, width: 1, height: size.height)), with: .color(.red))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let t = Double(value.location.x) / size.width * duration
            pan(to: t - visibleLength / 2, duration: duration)
        })
        .help("The whole recording: click or drag to show another part")
    }
}

/// Catches scroll-wheel events over a view (passing clicks and drags through to it), with the pointer's location in
/// the view (origin top left).
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (NSEvent, CGPoint) -> Void

    final class CatcherView: NSView {
        var onScroll: ((NSEvent, CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event, convert(event.locationInWindow, from: nil))
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }
}

// MARK: Cuts

private struct VinylCutList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let vinyl: VinylController
    let item: CollectionItem

    /// "A1 · So What", the cut's track's name.
    static func name(_ seg: VinylSegment, options: [VinylController.TargetOption]) -> String? {
        switch seg.target {
        case .release?: options.first { $0.target == seg.target }.map { "\($0.label) · \($0.title)" }
        case .manual(let n, let title)?: title.isEmpty ? "\(n)" : "\(n) · \(title)"
        case nil: nil
        }
    }

    var body: some View {
        let options = vinyl.targetOptions
        let rate = Double(vinyl.session?.format.sampleRate ?? 44_100)
        VStack(alignment: .leading, spacing: 8) {
            if item.releaseID == nil {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "info.circle").foregroundStyle(.subtext)
                    Text("This record isn't matched to an edition on MusicBrainz, so name each track yourself, or choose the edition to name them from its track list.")
                        .font(.callout)
                    Button("Change Edition…") { model.collectionSheet = .changeEdition(itemID: item.id) }
                }
            } else if vinyl.isLoadingRelease {
                Label("Downloading the track list…", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.subtext)
            } else if let error = vinyl.releaseError {
                HStack {
                    Text(error).font(.callout)
                    Button("Try Again") { vinyl.reloadRelease() }
                }
            }
            if vinyl.segments.isEmpty {
                Text("No tracks yet. Move the playhead to a song's start and Split at Playhead.")
                    .font(.callout).foregroundStyle(.subtext)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vinyl.segments.enumerated()), id: \.element.id) { k, seg in
                        row(k, seg, options: options, rate: rate)
                        if k < vinyl.segments.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.fill))
            }
        }
    }

    private func row(_ k: Int, _ seg: VinylSegment, options: [VinylController.TargetOption], rate: Double) -> some View {
        let selected = seg.id == vinyl.selectedSegmentID
        let option = options.first { $0.target == seg.target }
        let twice = seg.target != nil && vinyl.segments.prefix(k).contains { $0.target == seg.target }
        let length = Double(seg.end - seg.start) / rate
        return HStack(spacing: 10) {
            Text("\(k + 1)").font(.callout.monospacedDigit()).foregroundStyle(.subtext).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(VinylText.time(Double(seg.start) / rate)) – \(VinylText.time(Double(seg.end) / rate))").font(.callout.monospacedDigit())
                HStack(spacing: 4) {
                    Text(formatTime(length)).font(.caption.monospacedDigit()).foregroundStyle(.subtext)
                    if let d = option?.duration, abs(d - length) > 8 {
                        Text("(album: \(formatTime(d)))").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                            .help("This track is \(formatTime(d)) on the album: the cut may be off")
                    }
                }
            }
            .frame(width: 170, alignment: .leading)
            Group {
                if seg.isSaved {
                    Label(Self.name(seg, options: options) ?? "Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).lineLimit(1)
                } else if vinyl.release != nil {
                    Picker("Track", selection: Binding(get: { seg.target }, set: { vinyl.setTarget(seg.id, $0) })) {
                        Text("Don't Save").tag(VinylTarget?.none)
                        Divider()
                        ForEach(options) { o in
                            Text("\(o.label)  \(o.title)\(o.duration.map { "  (\(formatTime($0)))" } ?? "")\(o.isDone ? " — in your digital collection" : "")")
                                .tag(Optional(o.target))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 380)
                } else if item.releaseID == nil {
                    manualFields(seg)
                } else {
                    Text("–").foregroundStyle(.subtext)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if option?.isDone == true, !seg.isSaved {
                Text("Already in your digital collection").font(.caption).foregroundStyle(.orange)
            } else if twice, !seg.isSaved {
                Text("Chosen for another cut too").font(.caption).foregroundStyle(.orange)
            }
            Button { vinyl.playPreview(from: seg.start, to: seg.end) } label: { Image(systemName: "play.fill") }
                .help("Play this track from its start")
            Button { vinyl.playEnd(of: seg) } label: { Image(systemName: "forward.end.fill") }
                .help("Play its last 5 seconds")
            Button { vinyl.deleteSegment(seg.id) } label: { Image(systemName: "trash") }
                .disabled(seg.isSaved)
                .help("Delete this cut")
        }
        .buttonStyle(.borderless)
        .disabled(vinyl.state == .recording || vinyl.state == .paused)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? theme.accent.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vinyl.selectedSegmentID = seg.id
            vinyl.seek(to: seg.start)
        }
    }

    /// A record MusicBrainz doesn't know: the track's number and title, typed.
    @ViewBuilder
    private func manualFields(_ seg: VinylSegment) -> some View {
        let (number, title): (Int, String) = {
            if case .manual(let n, let t)? = seg.target { return (n, t) }
            return (0, "")
        }()
        HStack(spacing: 8) {
            if seg.target == nil {
                Button("Name This Track") { vinyl.setTarget(seg.id, .manual(number: vinyl.nextManualNumber(), title: "")) }
            } else {
                Stepper(value: Binding(get: { number }, set: { vinyl.setTarget(seg.id, .manual(number: max(1, $0), title: title)) }), in: 1...99) {
                    Text("Track \(number)").font(.callout.monospacedDigit())
                }
                .fixedSize()
                TextField("Title", text: Binding(get: { title }, set: { vinyl.setTarget(seg.id, .manual(number: number, title: $0)) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button { vinyl.setTarget(seg.id, nil) } label: { Image(systemName: "xmark.circle") }
                    .help("Don't save this cut")
            }
        }
    }
}
