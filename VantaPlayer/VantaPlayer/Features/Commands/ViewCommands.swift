import SwiftUI

struct ViewCommands: Commands {
    @AppStorage(AppStorageKeys.isCompactMode) private var isCompactMode = false
    @AppStorage(AppStorageKeys.isPlaylistVisible) private var isPlaylistVisible = true
    @AppStorage(AppStorageKeys.isInspectorVisible) private var isInspectorVisible = true
    @AppStorage(AppStorageKeys.densityMode) private var densityModeRawValue = DensityMode.comfortable.rawValue

    private var densityModeBinding: Binding<DensityMode> {
        Binding(
            get: { DensityMode(rawValue: densityModeRawValue) ?? .comfortable },
            set: { densityModeRawValue = $0.rawValue }
        )
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Toggle Compact Mode") {
                isCompactMode.toggle()
            }
            .keyboardShortcut("c", modifiers: [.control, .command])

            Button("Toggle Playlist") {
                guard !isCompactMode else { return }
                isPlaylistVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(isCompactMode)

            Button("Toggle Inspector") {
                guard !isCompactMode else { return }
                isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(isCompactMode)

            Divider()

            Picker("Density", selection: densityModeBinding) {
                ForEach(DensityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }
}
