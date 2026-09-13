import SwiftUI

struct QRCodeSheet: View {
    let onAdd: (QRCode) throws -> Void
    @State private var input = ""
    @State private var code: QRCode?
    @State private var preview: UIImage?
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $input)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(generate)
                        .accessibilityIdentifier("editor.qrURL")
                    Button("QRコードを生成", action: generate)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("editor.generateQR")
                } footer: {
                    Text("http://・https://がない場合はhttps://を付けます。")
                }
                if let preview, let code {
                    Section {
                        Image(uiImage: preview).resizable().interpolation(.none)
                            .scaledToFit().frame(maxWidth: 240, maxHeight: 240)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("生成したQRコード")
                            .accessibilityIdentifier("editor.qrPreview")
                        Text(code.url).font(.caption).textSelection(.enabled)
                        Button("名刺に追加") {
                            do { try onAdd(code); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                        .disabled(!code.canAddToCanvas)
                        .accessibilityIdentifier("editor.addQRToCanvas")
                    } footer: {
                        Text(code.canAddToCanvas
                             ? "名刺に画像として追加します。追加後に位置やサイズを調整できます。"
                             : "名刺に読み取りやすく載せるにはURLが長すぎます。短いURLを入力してください。")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.qrError") }
                }
            }
            .navigationTitle("QRコードを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { focused = true }
            .onChange(of: input) { _, _ in code = nil; preview = nil; error = nil }
        }
    }

    private func generate() {
        code = nil
        preview = nil
        error = nil
        do {
            let generated = try QRCode.generate(input)
            preview = try generated.image(scale: generated.previewScale)
            code = generated
            focused = false
        } catch { self.error = error.localizedDescription }
    }
}
