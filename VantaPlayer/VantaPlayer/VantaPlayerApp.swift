import SwiftUI

@main
struct VantaPlayerApp: App {
    @StateObject private var playerViewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            PlayerView(viewModel: playerViewModel)
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Audio Files…") {
                    playerViewModel.openFilesPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Playback") {
                Button(playerViewModel.isPlaying ? "Pause" : "Play") {
                    playerViewModel.togglePlayPause()
                }

                Button("Previous Track") {
                    playerViewModel.playPrevious()
                }

                Button("Next Track") {
                    playerViewModel.playNext()
                }

                Divider()

                Button("Seek Backward 5 Seconds") {
                    playerViewModel.seek(by: -5)
                }

                Button("Seek Forward 5 Seconds") {
                    playerViewModel.seek(by: 5)
                }

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
