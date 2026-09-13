import SwiftUI

/// A normal SwiftUI form keeps first-entry edits and confirmation in one state lifetime.
struct TextEntrySheet: View {
    let title: String
    let prompt: String
    let explanation: String
    let confirmationTitle: String
    let fieldIdentifier: String
    let confirmationIdentifier: String
    let isURL: Bool
    let onClearURL: (() -> Void)?
    let onConfirm: (String) -> Void

    @State private var value: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, prompt: String, explanation: String = "", confirmationTitle: String,
         fieldIdentifier: String, confirmationIdentifier: String, initialValue: String = "",
         isURL: Bool = false, onClearURL: (() -> Void)? = nil, onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.explanation = explanation
        self.confirmationTitle = confirmationTitle
        self.fieldIdentifier = fieldIdentifier
        self.confirmationIdentifier = confirmationIdentifier
        self.isURL = isURL
        self.onClearURL = onClearURL
        self.onConfirm = onConfirm
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(prompt, text: $value)
                        .keyboardType(isURL ? .URL : .default)
                        .textInputAutocapitalization(isURL ? .never : .sentences)
                        .autocorrectionDisabled(isURL)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(confirm)
                        .accessibilityIdentifier(fieldIdentifier)
                } footer: {
                    if !explanation.isEmpty { Text(explanation) }
                }
                if let onClearURL {
                    Section {
                        Button("URLをクリア", role: .destructive) {
                            onClearURL()
                            dismiss()
                        }
                        .accessibilityIdentifier("editor.clearURL")
                    } footer: {
                        Text("名刺のURLを削除し、タッチしてもURLが開かないようにします。画像更新やURLの再設定は引き続き使えます。")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationTitle, action: confirm)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(confirmationIdentifier)
                }
            }
            .onAppear {
                PerformanceTrace.event("TextEntry.requestFocus")
                focused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                PerformanceTrace.event("TextEntry.keyboardWillShow")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                PerformanceTrace.event("TextEntry.keyboardDidShow")
            }
        }
    }

    private func confirm() {
        let trace = PerformanceTrace.begin("TextEntry.confirm")
        defer { PerformanceTrace.end(trace) }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConfirm(value)
        dismiss()
    }
}
