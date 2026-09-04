import SwiftUI

struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPick: (Date) -> Void
    @State private var customDate = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            List {
                Section("Presets") {
                    Button("1 day") { pick(.day, 1) }
                    Button("2 days") { pick(.day, 2) }
                    Button("1 week") { pick(.day, 7) }
                    Button("1 month") { pick(.month, 1) }
                }
                Section("Custom") {
                    DatePicker("Wake date", selection: $customDate)
                    Button("Snooze until custom") {
                        onPick(customDate)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(MuseTheme.paper.opacity(0.55))
            .navigationTitle("Snooze")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(MuseCapsuleButtonStyle())
                }
            }
        }
        .frame(minWidth: 320, minHeight: 300)
    }

    private func pick(_ component: Calendar.Component, _ value: Int) {
        let date = Calendar.current.date(byAdding: component, value: value, to: Date()) ?? Date()
        onPick(date)
    }
}
