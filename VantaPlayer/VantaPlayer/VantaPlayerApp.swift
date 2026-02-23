import SwiftUI

@main
struct VantaPlayerApp: App {
    @StateObject private var playerViewModel = PlayerViewModel()
    @AppStorage("ui.playlist.visible") private var isPlaylistVisible = true
    @AppStorage("ui.inspector.visible") private var isInspectorVisible = true

    var body: some Scene {
        WindowGroup {
            PlayerView(
                viewModel: playerViewModel,
                isPlaylistVisible: $isPlaylistVisible,
                isInspectorVisible: $isInspectorVisible
            )
            .frame(minWidth: 520, minHeight: 420)
            .installWindowChrome()
        }
        .defaultSize(width: 700, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            ViewCommands(
                isPlaylistVisible: $isPlaylistVisible,
                isInspectorVisible: $isInspectorVisible
            )

            CommandGroup(after: .newItem) {
                Button("Open Audio Files…") {
                    playerViewModel.openFilesPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Import Folder…") {
                    playerViewModel.openFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Playback") {
                Button(playerViewModel.isPlaying ? "Pause" : "Play") {
                    playerViewModel.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playerViewModel.hasTracks)

                Button("Previous Track") {
                    playerViewModel.playPrevious()
                }
                .disabled(!playerViewModel.hasTracks)

                Button("Next Track") {
                    playerViewModel.playNext()
                }
                .disabled(!playerViewModel.hasTracks)

                Divider()

                Button("Seek Backward 5 Seconds") {
                    playerViewModel.seek(by: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!playerViewModel.hasTracks)

                Button("Seek Forward 5 Seconds") {
                    playerViewModel.seek(by: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!playerViewModel.hasTracks)

                Divider()

                Button("Volume Up") {
                    playerViewModel.adjustVolume(by: 0.04)
                }

                Button("Volume Down") {
                    playerViewModel.adjustVolume(by: -0.04)
                }
            }
        }
    }
}
