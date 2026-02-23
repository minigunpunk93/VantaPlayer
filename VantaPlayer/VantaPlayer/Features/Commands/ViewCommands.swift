import SwiftUI

struct ViewCommands: Commands {
    @Binding var isPlaylistVisible: Bool
    @Binding var isInspectorVisible: Bool

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Toggle Playlist") {
                isPlaylistVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("Toggle Inspector") {
                isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
