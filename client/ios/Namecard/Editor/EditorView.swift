import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import NamecardCore

struct EditorView: View {
    @Bindable var model: EditorModel
    let onSave: (Data, ImageFormat) -> Void
    let onExport: (Data, ImageFormat) -> Void
    let onWrite: (Data, ImageFormat) -> Void
    let onURL: (String) -> Void
    var writeUnavailableReason: String? = nil

    @State private var photo: PhotosPickerItem?
    @State private var importingImage = false
    @State private var addingText = false
    @State private var settingURL = false
    @State private var confirmingClear = false
    @State private var urlInput = ""
    @State private var confirmedURL: String?
    @State private var errorMessage: String?
    private struct Preview: Identifiable {
        let id = UUID()
        let image: UIImage
        let format: ImageFormat
    }
    @State private var preview: Preview?
    @State private var loadingImage = false

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    EditorCanvasView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                        }
                        .accessibilityIdentifier("editor.canvas")
                    if !model.viewport.isDefault {
                        Button("表示をリセット", systemImage: "viewfinder", action: model.resetViewport)
                            .font(.caption)
                            .adaptiveGlassButtonStyle(prominent: true)
                            .padding(10)
                    }
                    if loadingImage {
                        ProgressView("画像を読み込み中")
                            .padding()
                            .adaptiveGlassStatusSurface()
                            .padding(10)
                    }
                }
                .frame(minHeight: 220)
                .padding(.horizontal, 12)

                Text("要素をドラッグで移動、2本指で拡縮・回転。灰色の余白から操作すると紙面表示を調整できます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)

                tools

                VStack(spacing: 6) {
                    Button {
                        guard model.format == .dotDensity, writeUnavailableReason == nil else { return }
                        render(onWrite)
                    } label: {
                        Label("名刺に書き込む", systemImage: "wave.3.right")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .adaptiveGlassButtonStyle(prominent: true)
                    .disabled(model.format == .gray4 || writeUnavailableReason != nil)
                    .accessibilityIdentifier("editor.write")
                    if model.format == .gray4 {
                        Text("4階調の保存・BIN入出力に対応しています。現在の名刺FWでは更新に必要な待機時間がiPhoneのNFCセッションに収まらないため、4階調の書き込みは利用できません。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("editor.gray4.explanation")
                    } else if let writeUnavailableReason {
                        Text(writeUnavailableReason)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("editor.hardware.explanation")
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .padding(.top, 6)
        }
        .navigationTitle("New")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("画像方式", selection: $model.format) {
                    Text("ドット密度").tag(ImageFormat.dotDensity)
                    Text("4階調").tag(ImageFormat.gray4)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("editor.format")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("元に戻す", systemImage: "arrow.uturn.backward", action: model.undo)
                    .disabled(!model.canUndo)
                    .accessibilityIdentifier("editor.undo")
                Button("やり直す", systemImage: "arrow.uturn.forward", action: model.redo)
                    .disabled(!model.canRedo)
                    .accessibilityIdentifier("editor.redo")
                Menu {
                    Button("プレビュー", systemImage: "eye") { createPreview() }
                    Button("Libraryに保存", systemImage: "square.and.arrow.down") { render(onSave) }
                        .accessibilityIdentifier("editor.save")
                    Button("BINを書き出す", systemImage: "square.and.arrow.up") { render(onExport) }
                        .accessibilityIdentifier("editor.export")
                } label: {
                    Label("保存とプレビュー", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("editor.output")
            }
        }
        .sheet(isPresented: $addingText) {
            TextEntrySheet(title: "テキストを追加", prompt: "テキスト", confirmationTitle: "追加",
                           fieldIdentifier: "editor.text", confirmationIdentifier: "editor.confirmText",
                           onConfirm: model.addText)
        }
        .sheet(isPresented: $settingURL, onDismiss: {
            guard let url = confirmedURL else { return }
            confirmedURL = nil
            onURL(url)
        }) {
            TextEntrySheet(title: "URLを設定", prompt: "https://example.com",
                           explanation: "通常のタッチで開くURLを設定します。http://・https://がない場合はhttps://を付けます。",
                           confirmationTitle: "書き込む", fieldIdentifier: "editor.url",
                           confirmationIdentifier: "editor.confirmURL", initialValue: urlInput, isURL: true) {
                urlInput = $0
                confirmedURL = $0
            }
        }
        .confirmationDialog("すべての要素を消去しますか？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("全消去", role: .destructive, action: model.clear)
        } message: { Text("消去後も「元に戻す」で復元できます。") }
        .alert("操作を完了できませんでした", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.jpeg, .png, .webP]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try model.addImage(data: Data(contentsOf: url))
            } catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { @MainActor in
                loadingImage = true
                defer { loadingImage = false; photo = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw EditorError.unreadableImage
                    }
                    try model.addImage(data: data)
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .sheet(item: $preview) { rendered in
            NavigationStack {
                VStack(spacing: 24) {
                    Image(uiImage: rendered.image).resizable().interpolation(.none)
                        .aspectRatio(296.0 / 128, contentMode: .fit)
                        .border(.secondary).padding()
                        .accessibilityLabel("完成画像プレビュー")
                        .accessibilityIdentifier("editor.previewImage")
                    Text("\(rendered.format == .gray4 ? "4階調" : "ドット密度") · 296 × 128")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("実際の表示は電子ペーパーの状態や光の当たり方で異なります。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                .navigationTitle("完成画像")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { preview = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidGlassControlGroup(spacing: 10) {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        toolLabel("写真", symbol: "photo.on.rectangle")
                    }
                    .disabled(loadingImage)
                    Button { importingImage = true } label: { toolLabel("ファイル", symbol: "folder") }
                    Button { addingText = true } label: { toolLabel("テキスト", symbol: "textformat") }
                        .accessibilityIdentifier("editor.addText")
                    Button { settingURL = true } label: { toolLabel("URL", symbol: "link") }
                        .accessibilityIdentifier("editor.setURL")
                    Button(action: model.moveBackward) { toolLabel("背面へ", symbol: "square.3.layers.3d.bottom.filled") }
                        .disabled(!model.canMoveBackward)
                    Button(action: model.moveForward) { toolLabel("前面へ", symbol: "square.3.layers.3d.top.filled") }
                        .disabled(!model.canMoveForward)
                    Menu {
                        Button("左へ1px", systemImage: "arrow.left") { model.adjustSelection(pan: CGPoint(x: -1, y: 0)) }
                        Button("右へ1px", systemImage: "arrow.right") { model.adjustSelection(pan: CGPoint(x: 1, y: 0)) }
                        Button("上へ1px", systemImage: "arrow.up") { model.adjustSelection(pan: CGPoint(x: 0, y: -1)) }
                        Button("下へ1px", systemImage: "arrow.down") { model.adjustSelection(pan: CGPoint(x: 0, y: 1)) }
                        Button("拡大", systemImage: "plus.magnifyingglass") { model.adjustSelection(zoom: 1.1) }
                        Button("縮小", systemImage: "minus.magnifyingglass") { model.adjustSelection(zoom: 1 / 1.1) }
                        Button("時計回りに15°", systemImage: "rotate.right") { model.adjustSelection(rotation: .pi / 12) }
                        Button("反時計回りに15°", systemImage: "rotate.left") { model.adjustSelection(rotation: -.pi / 12) }
                    } label: { toolLabel("調整", symbol: "slider.horizontal.3") }
                        .disabled(!model.hasSelection)
                    Button(action: model.deleteSelection) { toolLabel("削除", symbol: "trash") }
                        .disabled(!model.hasSelection)
                    Button { model.gridEnabled.toggle() } label: { toolLabel("グリッド", symbol: "grid", selected: model.gridEnabled) }
                        .accessibilityValue(model.gridEnabled ? "オン" : "オフ")
                    Button { model.snapEnabled.toggle() } label: { toolLabel("スナップ", symbol: "scope", selected: model.snapEnabled) }
                        .accessibilityValue(model.snapEnabled ? "オン" : "オフ")
                    Button { confirmingClear = true } label: { toolLabel("全消去", symbol: "trash.slash") }
                        .disabled(!model.hasContent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func toolLabel(_ title: String, symbol: String, selected: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 64, height: 40)
                .adaptiveGlassToolSurface(selected: selected)
            Text(title).font(.caption)
        }
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }

    private func render(_ completion: (Data, ImageFormat) -> Void) {
        do { completion(try model.renderNativeImage(), model.format) }
        catch { errorMessage = error.localizedDescription }
    }

    private func createPreview() {
        do {
            preview = Preview(image: try EditorModel.image(data: model.renderNativeImage(), format: model.format),
                              format: model.format)
        } catch { errorMessage = error.localizedDescription }
    }
}
