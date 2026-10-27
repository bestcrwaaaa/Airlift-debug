import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Palette

/// The console's colour scheme: a dark instrument panel, one accent, and the
/// usual traffic lights for state.
private enum Palette {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.075)
    static let surface = Color(red: 0.068, green: 0.082, blue: 0.122)
    static let surfaceHigh = Color(red: 0.105, green: 0.125, blue: 0.175)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.31, green: 0.86, blue: 0.95)
    static let success = Color(red: 0.36, green: 0.90, blue: 0.55)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let warning = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let text = Color(red: 0.88, green: 0.91, blue: 0.96)
    static let dim = Color(red: 0.54, green: 0.60, blue: 0.70)
}

// MARK: - Card

/// A titled panel. The console is a stack of these.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Palette.dim)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Console

/// The debug console: a path, an editor, and the six operations that turn
/// one into the other.
///
/// Every operation rides the AirTraffic/ATAirlock escape the app already
/// uses — the console adds a path input, a text editor, and the share sheet
/// on top of it.
struct DebugConsoleView: View {
    @StateObject private var vm = DebugViewModel()
    /// The announcements screen, so the console can tell whether the device
    /// is free and whether a pairing file exists.
    @ObservedObject private var main = SilenceViewModel.shared

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showWriteConfirm = false
    @State private var showLog = true

    private var canOperate: Bool {
        !vm.busy && main.pairingReady && !main.busy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                pathCard
                actionCard
                statusBanner
                contentCard
                if !vm.entries.isEmpty { directoryCard }
                logCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Palette.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Debug console")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        // A path can arrive over the URL scheme before this screen is on
        // display, so the console asks for it when it appears — and again
        // whenever a new request comes in while it is already open.
        .onAppear { vm.consumePendingRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .debugConsoleRequest)) { _ in
            vm.consumePendingRequest()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .content, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.adoptImportedFile(at: url) }
            case .failure(let error):
                vm.log.append(String(localized: "Import failed: \(error.localizedDescription)"))
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: vm.exportDocument,
            contentType: .data,
            defaultFilename: vm.exportName
        ) { result in
            switch result {
            case .success:
                vm.log.append(String(localized: "Saved to the Files app"))
            case .failure(let error):
                vm.log.append(String(localized: "Export failed: \(error.localizedDescription)"))
            }
        }
        .confirmationDialog(
            "Write to the device?",
            isPresented: $showWriteConfirm,
            titleVisibility: .visible
        ) {
            Button("Write the whole payload", role: .destructive) { vm.write() }
            Button("Write the selection only", role: .destructive) { vm.write(onlySelection: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The payload is written to \(vm.path) on this iPhone, outside the app's sandbox. There is no undo.")
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Palette.accent, Palette.accent.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(red: 0.03, green: 0.06, blue: 0.10))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AirLift Debug")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                    Text("DEVICE CONSOLE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Palette.accent.opacity(0.85))
                }
                Spacer(minLength: 0)
                pairingPill
            }

            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("Debug build — reads and writes go straight to the device filesystem through the AirTraffic escape.")
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.warning)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Palette.surfaceHigh, Palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Palette.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private var pairingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(main.pairingReady ? Palette.success : Palette.danger)
                .frame(width: 7, height: 7)
            Text(main.pairingReady ? "PAIRED" : "NOT PAIRED")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(main.pairingReady ? Palette.success : Palette.danger)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background((main.pairingReady ? Palette.success : Palette.danger).opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: path

    private var pathCard: some View {
        Card(title: "Target path", systemImage: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("/var/mobile/…", text: $vm.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(10)
                    .background(Palette.surfaceHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Palette.accent.opacity(0.30), lineWidth: 1)
                    )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        chip("Announcement", path: DebugPaths.announcement)
                        chip("Greetings", path: DebugPaths.greetings)
                        chip("Media", path: DebugPaths.media)
                        chip("Library", path: DebugPaths.library)
                        chip("Preferences", path: DebugPaths.preferences)
                        chip("/var/mobile", path: DebugPaths.mobile)
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private func chip(_ title: String, path: String) -> some View {
        Button {
            vm.path = path
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.accent.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Palette.accent.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: actions

    private var actionCard: some View {
        Card(title: "Operations", systemImage: "bolt.horizontal.fill") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                actionButton("Read", systemImage: "arrow.down.doc.fill", tint: Palette.accent, enabled: canOperate) {
                    vm.read()
                }
                actionButton("Write", systemImage: "arrow.up.doc.fill", tint: Palette.warning, enabled: canOperate) {
                    showWriteConfirm = true
                }
                actionButton("Export", systemImage: "square.and.arrow.up.fill", tint: Palette.success, enabled: vm.payloadData() != nil) {
                    vm.prepareExport()
                }
                actionButton("Import", systemImage: "square.and.arrow.down.fill", tint: Palette.accent, enabled: !vm.busy) {
                    showImporter = true
                }
                actionButton("Browse", systemImage: "folder.fill", tint: Palette.accent, enabled: canOperate) {
                    vm.browse()
                }
                actionButton("Save to Files", systemImage: "internaldrive.fill", tint: Palette.dim, enabled: vm.exportDocument != nil) {
                    showExporter = true
                }
            }

            if let url = vm.exportURL {
                ShareLink(item: url) {
                    Label("Share the exported file", systemImage: "paperplane.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(Color(red: 0.03, green: 0.06, blue: 0.10))
                        .background(Palette.success)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(enabled ? tint : Palette.dim.opacity(0.5))
            .background(Palette.surfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(enabled ? 0.32 : 0.08), lineWidth: 1)
            )
        }
        .disabled(!enabled)
    }

    // MARK: status

    @ViewBuilder
    private var statusBanner: some View {
        switch vm.status {
        case .idle:
            EmptyView()
        case let .working(text):
            banner(text: text, tint: Palette.accent, systemImage: "arrow.triangle.2.circlepath")
        case let .success(text):
            banner(text: text, tint: Palette.success, systemImage: "checkmark.circle.fill")
        case let .warning(text):
            banner(text: text, tint: Palette.warning, systemImage: "exclamationmark.triangle.fill")
        case let .failure(text):
            banner(text: text, tint: Palette.danger, systemImage: "xmark.octagon.fill")
        }
    }

    private func banner(text: String, tint: Color, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: content

    private var contentCard: some View {
        Card(title: "Content", systemImage: "curlybraces.square.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Source", selection: $vm.source) {
                        ForEach(DebugSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        vm.showHex.toggle()
                    } label: {
                        Image(systemName: vm.showHex ? "number" : "textformat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(vm.showHex ? Palette.accent : Palette.dim)
                            .padding(8)
                            .background(Palette.surfaceHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }

                HStack(spacing: 10) {
                    Text("\(vm.content.count) char")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                    Text("\(vm.payloadSize.formatted()) B payload")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                    Spacer(minLength: 0)
                    if vm.source == .imported, let name = vm.importedName {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                    }
                }

                TextEditor(text: $vm.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .frame(minHeight: 210)
                    .background(Palette.surfaceHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    )

                selectionControls
            }
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("Select content")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Button("All") { vm.selectAll() }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            HStack(spacing: 8) {
                rangeField("Start", value: $vm.selectionStart)
                rangeField("End", value: $vm.selectionEnd)
            }

            Text(vm.selectedText.isEmpty ? "Nothing selected" : String(vm.selectedText.prefix(400)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(vm.selectedText.isEmpty ? Palette.dim : Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Palette.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 8) {
                smallButton("Copy", systemImage: "doc.on.doc") { vm.copySelection() }
                smallButton("Keep only", systemImage: "scissors") { vm.extractSelection() }
                smallButton("Load import", systemImage: "arrow.down.doc") { vm.loadImportedIntoEditor() }
            }
        }
    }

    private func rangeField(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.dim)
            TextField("0", value: value, format: .number)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Palette.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(Palette.text)
                .background(Palette.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        }
    }

    // MARK: directory

    private var directoryCard: some View {
        Card(title: "Directory", systemImage: "list.bullet.rectangle.portrait.fill") {
            VStack(spacing: 0) {
                ForEach(vm.entries) { entry in
                    Button {
                        vm.open(entry)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.isDirectory ? Palette.accent : Palette.dim)
                            Text(entry.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if !entry.isDirectory {
                                Text(entry.size.formatted())
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Palette.dim)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.dim.opacity(0.7))
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    if entry.id != vm.entries.last?.id {
                        Divider().overlay(Palette.stroke)
                    }
                }
                Button {
                    vm.goUp()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text("One level up")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: log

    private var logCard: some View {
        Card(title: "Console", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(vm.log.count) line(s)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { showLog.toggle() }
                    } label: {
                        Text(showLog ? "Hide" : "Show")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                }
                if showLog {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(logColor(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .padding(9)
                    .background(Palette.surfaceHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        if line.hasPrefix("✗") { return Palette.danger }
        if line.hasPrefix("✓") { return Palette.success }
        if line.hasPrefix("──") { return Palette.accent }
        return Palette.dim
    }
}
