import SwiftUI

struct RapKeyboardCommands: Commands {
    @FocusedValue(\.rapActions) private var actions

    var body: some Commands {
        CommandMenu("Message") {
            Button("Archive") { actions?.archive() }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Flag") { actions?.flag() }
                .keyboardShortcut("l", modifiers: [.shift, .command])
            Button("File…") { actions?.file() }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Button("Snooze…") { actions?.snooze() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Divider()
            Button("Next Message") { actions?.next() }
                .keyboardShortcut(.downArrow, modifiers: [.option])
            Button("Previous Message") { actions?.prev() }
                .keyboardShortcut(.upArrow, modifiers: [.option])
        }
    }
}
