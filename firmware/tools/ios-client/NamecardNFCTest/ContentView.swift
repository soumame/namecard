import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = NFCController()
    @State private var showingImagePicker = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        Button("1. 接続・STATUS確認") {
                            controller.startStatus()
                        }
                        .buttonStyle(TestButtonStyle(color: .blue))

                        Button("2. iOS 10秒無通信・給電維持試験") {
                            controller.startSilentPowerTest()
                        }
                        .buttonStyle(TestButtonStyle(color: .orange))

                        Text("内蔵パターン（画像転送なし）")
                            .font(.headline)
                        Picker("パターン", selection: $controller.selectedPatternID) {
                            ForEach(1...NFCController.patternNames.count, id: \.self) { id in
                                Text(NFCController.patternNames[id - 1]).tag(id)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("3. 選択パターンを書き換え（1 byte）") {
                            controller.startSelectedPattern()
                        }
                        .buttonStyle(TestButtonStyle(color: .green))

                        Button("4. 10種類を連続書き換え") {
                            controller.startPatternSequence()
                        }
                        .buttonStyle(TestButtonStyle(color: .purple))

                        if controller.continuousNextPattern > 1 {
                            Button("連続試験を\(controller.continuousNextPattern)番から続行") {
                                controller.startPatternSequence(reset: false)
                            }
                            .buttonStyle(TestButtonStyle(color: .purple))
                        }

                        Button("5. 内蔵チェック画像を選択") {
                            controller.loadBuiltInCheckerImage()
                        }
                        .buttonStyle(TestButtonStyle(color: .gray))

                        Button("またはFilesから4,736-byte画像を選択") {
                            showingImagePicker = true
                        }
                        .buttonStyle(TestButtonStyle(color: .gray))
                        Text("選択中: \(controller.imageName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("6. 選択画像を分割転送・更新") {
                            controller.startImageTransfer()
                        }
                        .buttonStyle(TestButtonStyle(color: .indigo))
                    }
                    .disabled(controller.running)

                    if controller.running {
                        HStack {
                            ProgressView()
                            Text("Core NFCセッション実行中。iPhone上端を固定してください。")
                                .font(.callout)
                        }
                    }

                    HStack {
                        Text("ログ")
                            .font(.headline)
                        Spacer()
                        Button("消去") { controller.clearLog() }
                            .disabled(controller.running)
                    }
                    Text(controller.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 220,
                               alignment: .topLeading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)

                    Text("最初は『10秒無通信・給電維持試験』を実行してください。"
                         + "Core NFCは約60秒で終了するため、アプリは48〜55秒で安全停止します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Namecard NFC Test")
        }
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { controller.loadImage(from: url) }
            case .failure(let error):
                // loadImage owns normal file errors; picker cancellation does not
                // need to replace the current image selection.
                if (error as NSError).code != NSUserCancelledError {
                    controller.clearLog()
                }
            }
        }
    }
}

private struct TestButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.65 : 0.90))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
