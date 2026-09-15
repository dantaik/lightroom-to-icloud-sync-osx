#if os(macOS)
import AppKit
import LightroomSyncCore
import SwiftUI

/// The whole UI: a single panel under the menu bar icon.
struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            settings
            saveBar
            Divider()
            activity
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.menuSymbol)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lightroom → iCloud Photos")
                    .font(.headline)
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lightroom album share link")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                TextField("https://adobe.ly/… or https://lightroom.adobe.com/shares/…",
                          text: $model.editor.draft.shareLink)
                    .textFieldStyle(.roundedBorder)
                if !model.shareStatus.isEmpty {
                    Text(model.shareStatus)
                        .font(.caption)
                        .foregroundStyle(model.shareStatusIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.availableAlbums.count > 1 {
                    Picker("Album", selection: $model.editor.draft.albumID) {
                        Text("First album").tag(nil as String?)
                        ForEach(model.availableAlbums) { album in
                            Text(album.name).tag(Optional(album.id))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Photos album (optional)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                TextField("Leave empty to add photos to the library only",
                          text: $model.editor.draft.photosAlbumName)
                    .textFieldStyle(.roundedBorder)
            }

            Stepper(value: $model.editor.draft.intervalMinutes, in: SyncSettings.intervalRange) {
                Text("Check every \(model.editor.draft.intervalMinutes) min")
            }
            Text("New photos sync once they have been in the album for at least this long.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Start at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .help("Checks run on the saved settings only.")
            if model.hasUnsavedChanges {
                Button("Revert") { model.revert() }
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            } else if model.hasSavedSettings {
                Text("Settings saved")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent activity")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            if model.activity.isEmpty {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(Array(model.activity.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isSyncing ? "Syncing…" : "Sync now") { model.syncNow() }
                .disabled(!model.canSync)
                .help(model.syncNowHelp)
            Button("Open log") { model.openLog() }
            Spacer()
            Button("Quit") { model.quit() }
        }
    }
}
#endif
