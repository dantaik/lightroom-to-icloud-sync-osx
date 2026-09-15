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
            statusIndicator
                .frame(width: 16, height: 16)
                .padding(.top, 2)

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

                if case .syncing(let completed, let total) = model.phase, total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if model.statusKind == .syncing {
            ProgressView()
                .controlSize(.small)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
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

    private var statusColor: Color {
        switch model.statusKind {
        case .ok: return .green
        case .syncing: return .accentColor
        case .unsaved: return .orange
        case .failed: return .red
        case .unconfigured: return .secondary
        }
    }

    // MARK: Settings

    private var lightroomSection: some View {
        VStack(alignment: .leading, spacing: Metrics.withinSection) {
            sectionHeader("Lightroom album")

            TextField("https://adobe.ly/… or lightroom.adobe.com/shares/…",
                      text: $model.editor.draft.shareLink)
                .textFieldStyle(.roundedBorder)

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

            caption("Created if it does not exist, and refilled if you delete it.")
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

            caption("A new photo syncs once it has been in the album this long, which leaves time for your first edits.")

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
            Button("Save") { model.save() }
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

            Button("About") { model.showAbout() }
                .buttonStyle(.link)
                .help("What this app does, what it cannot do, and where the source lives")

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
