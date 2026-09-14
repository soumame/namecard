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
    let textStyle: Binding<EditorTextStyle>?
    let onConfirm: (String) -> Void

    @State private var value: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, prompt: String, explanation: String = "", confirmationTitle: String,
         fieldIdentifier: String, confirmationIdentifier: String, initialValue: String = "",
         isURL: Bool = false, onClearURL: (() -> Void)? = nil, textStyle: Binding<EditorTextStyle>? = nil,
         onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.explanation = explanation
        self.confirmationTitle = confirmationTitle
        self.fieldIdentifier = fieldIdentifier
        self.confirmationIdentifier = confirmationIdentifier
        self.isURL = isURL
        self.onClearURL = onClearURL
        self.textStyle = textStyle
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
                if let textStyle {
                    TextFormattingControls(style: textStyle, value: value)
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

private struct TextFormattingControls: View {
    @Binding var style: EditorTextStyle
    let value: String

    var body: some View {
        Section("書式") {
            HStack(spacing: 12) {
                styleButton("太字", symbol: "bold", selected: $style.bold, identifier: "editor.text.bold")
                styleButton("斜体", symbol: "italic", selected: $style.italic, identifier: "editor.text.italic")
                styleButton("下線", symbol: "underline", selected: $style.underline, identifier: "editor.text.underline")
            }
            NavigationLink {
                TextFontFamilyPicker(selection: $style.fontFamily)
            } label: {
                HStack {
                    Text("フォント")
                    Spacer()
                    Text(style.fontFamily ?? "システム").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityIdentifier("editor.text.font")
        }
        Section("プレビュー") {
            TextStylePreview(value: value.isEmpty ? "名刺 Namecard" : value, style: style)
                .frame(height: 64)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("editor.text.preview")
        }
    }

    private func styleButton(_ title: String, symbol: String, selected: Binding<Bool>, identifier: String) -> some View {
        Button { selected.wrappedValue.toggle() } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(selected.wrappedValue ? Color.accentColor : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityValue(selected.wrappedValue ? "オン" : "オフ")
        .accessibilityAddTraits(selected.wrappedValue ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

private struct TextFontFamilyPicker: View {
    @Binding var selection: String?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var families: [String] {
        EditorTextStyle.availableFontFamilies.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            familyRow("システム", family: nil)
            ForEach(families, id: \.self) { family in
                familyRow(family, family: family)
            }
        }
        .searchable(text: $search, prompt: "フォントを検索")
        .navigationTitle("フォント")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    private func familyRow(_ title: String, family: String?) -> some View {
        Button {
            selection = family
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selection == family { Image(systemName: "checkmark") }
            }
        }
        .accessibilityIdentifier("editor.text.font.\(family ?? "system")")
        .accessibilityAddTraits(selection == family ? [.isSelected] : [])
    }
}

/// UILabel uses the same UIKit attributes as the paper renderer, including synthesized font traits.
private struct TextStylePreview: UIViewRepresentable {
    let value: String
    let style: EditorTextStyle

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = NSAttributedString(string: value, attributes: style.attributes(at: 24))
    }
}
