#if os(macOS)
import AppKit
import LightroomSyncCore
import SwiftUI

/// The whole UI: one panel under the menu bar icon.
///
/// Three bands, separated by rules: what the app is doing now, the settings with their Save, and
/// the actions. The detail of each pass goes to the log file rather than on screen.
struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel

    /// The panel's text fields, so that saving can take focus off whichever one is being edited.
    private enum Field: Hashable {
        case shareLink, photosAlbum, fetchAtOnce, interval
    }

    @FocusState private var focusedField: Field?

    private enum Metrics {
        static let width: CGFloat = 400
        static let padding: CGFloat = 16
        static let betweenSections: CGFloat = 18
        static let withinSection: CGFloat = 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Metrics.padding)
                .padding(.top, Metrics.padding)
                .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: Metrics.betweenSections) {
                lightroomSection
                photosSection
                sizeSection
                fetchSection
                scheduleSection
                saveBar
            }
            .padding(Metrics.padding)

            Divider()

            footer
                .padding(.horizontal, Metrics.padding)
                .padding(.vertical, 12)
        }
        .frame(width: Metrics.width)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lightroom → iCloud Photos")
                    .font(.headline)

                Text(model.statusLine)
                    .font(.callout)
                    .foregroundStyle(statusTextColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let total = model.totalSyncedLine {
                    Text(total)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                progressBar
            }

            Spacer(minLength: 0)

            Button {
                model.showAbout()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("What this app does, what it cannot do, and where the source lives")
        }
    }

    /// Only a problem colors the status text; a healthy state stays quiet.
    private var statusTextColor: Color {
        switch model.statusKind {
        case .failed: return .red
        case .unsaved: return .orange
        default: return .secondary
        }
    }

    /// The bar under the status line.
    ///
    /// Once a pass has counted its photos the bar counts them off. Before that it cannot: the
    /// share has still to be read and the album still to be listed, and neither says in advance
    /// how long it will take. So the bar runs without a value, and the status line above it names
    /// the step — which is better than the nothing at all that used to show through the whole of
    /// the run-up, the longest silence in a pass on a large album.
    @ViewBuilder
    private var progressBar: some View {
        switch model.phase {
        case .preparing:
            ProgressView()
                .progressViewStyle(.linear)
                .padding(.top, 3)
        case .syncing(let completed, let total) where total > 0:
            ProgressView(value: Double(completed), total: Double(total))
                .progressViewStyle(.linear)
                .padding(.top, 3)
        case .idle, .failed, .syncing:
            EmptyView()
        }
    }

    // MARK: Settings

    private var lightroomSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Lightroom album")

            TextField("https://adobe.ly/… or lightroom.adobe.com/shares/…",
                      text: $model.editor.draft.shareLink)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .shareLink)

            if !model.shareStatus.isEmpty {
                Label {
                    Text(model.shareStatus)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: linkStatusSymbol)
                }
                .font(.caption)
                .foregroundStyle(linkStatusColor)
            }

            if model.availableAlbums.count > 1 {
                Picker("Album", selection: $model.editor.draft.albumID) {
                    Text("First album").tag(nil as String?)
                    ForEach(model.availableAlbums) { album in
                        Text(album.name).tag(Optional(album.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(.top, 2)
            }
        }
    }

    private var linkStatusSymbol: String {
        switch model.linkStatus {
        case .ok: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "info.circle"
        }
    }

    private var linkStatusColor: Color {
        switch model.linkStatus {
        case .ok: return .green
        case .problem: return .orange
        case .checking, .unknown: return .secondary
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Photos album")

            TextField("Optional — leave empty to add to the library only",
                      text: $model.editor.draft.photosAlbumName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .photosAlbum)

            caption("Created if it does not exist, and refilled if you delete it.")
        }
    }

    /// The size photos are synced at: the setting that decides how much of iCloud the album fills,
    /// and how much there is to download in the first place.
    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Photo size")

            Picker("", selection: $model.editor.draft.photoSize) {
                ForEach(PhotoSize.allCases) { size in
                    Text(size.menuLabel).tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            caption(model.editor.draft.photoSize.summary)
        }
    }

    /// How many photos are downloaded in parallel. A setting of its own rather than a row under
    /// the size: the two are unrelated, and the size section reads as one thing again without it.
    private var fetchSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Fetch at once")

            HStack(spacing: 6) {
                TextField("", value: $model.editor.draft.downloadConcurrency, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 54)
                    .focused($focusedField, equals: .fetchAtOnce)

                Stepper("", value: $model.editor.draft.downloadConcurrency,
                        in: SyncSettings.downloadConcurrencyRange)
                    .labelsHidden()

                Text(model.editor.draft.downloadConcurrency == 1 ? "photo" : "photos")
                    .foregroundStyle(Color.secondary)

                Spacer(minLength: 0)
            }

            caption("Lightroom renders each full-size photo on demand, and a check spends most of its time waiting for that. Fetching several at once overlaps the waiting. Lower it if the log says Lightroom is asking you to slow down.")
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Schedule")

            HStack(spacing: 6) {
                Text("Check every")

                Spacer(minLength: 0)

                TextField("", value: $model.editor.draft.intervalValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 54)
                    .focused($focusedField, equals: .interval)

                Stepper("", value: $model.editor.draft.intervalValue,
                        in: model.editor.draft.intervalUnit.range)
                    .labelsHidden()

                Picker("", selection: Binding(
                    get: { model.editor.draft.intervalUnit },
                    set: { model.setIntervalUnit($0) }
                )) {
                    ForEach(IntervalUnit.allCases) { unit in
                        Text(unit.pluralName).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }

            caption("How often the album is checked. A new photo waits this long before syncing, up to 15 minutes, which leaves time for your first edits.")

            Toggle("Start at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .padding(.top, 2)
        }
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Button("Save") {
                // Focus goes first, and not only to leave the panel at rest afterwards: a field
                // holding a number writes what is typed in it back to the draft when it stops
                // being edited, so the save has to come after that and not before it.
                focusedField = nil
                model.save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
            .help("Checks run on the saved settings only.")

            Button("Revert") { model.revert() }
                .disabled(!model.hasUnsavedChanges)

            Spacer(minLength: 0)

            Text(model.saveStateText)
                .font(.caption)
                .foregroundStyle(model.hasUnsavedChanges ? Color.orange : Color.secondary)
        }
    }

    // MARK: Actions

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.syncNow()
            } label: {
                Label(model.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canSync)
            .help(model.syncNowHelp)

            Button {
                model.openLog()
            } label: {
                Label("Open log", systemImage: "doc.plaintext")
            }
            .help("Every check writes what it did to ~/Library/Logs/LightroomSync/sync.log")

            Spacer(minLength: 0)

            Button("Quit") { model.quit() }
        }
    }

    // MARK: Building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .textCase(.uppercase)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
