import NamecardCore
import SwiftUI
import UniformTypeIdentifiers

struct NativeBINFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw AppFailure("BINを読み込めません。") }
        _ = try NativeImage.format(byteCount: data.count)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var exporting = false
    @State private var exportFile = NativeBINFile(Data())
    @State private var exportName = "namecard.bin"
    @State private var importing = false
    @State private var savePayload: Data?
    @State private var saveFormat = ImageFormat.dotDensity
    @State private var cardName = ""
    @State private var showSave = false
    @State private var renameCard: LibraryCard?
    @State private var showRename = false
    @State private var deleteCard: LibraryCard?
    @State private var showDelete = false


    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                EditorView(model: model.editor, onSave: { data, format in
                    savePayload = data; saveFormat = format; cardName = ""; showSave = true
                }, onExport: { data, format in export(data, name: "namecard-\(format == .gray4 ? "gray4" : "dither")") },
                   onWrite: { data, _ in model.nfc.writeImage(data, clean: model.cleanBeforeWrite) },
                   onURL: model.nfc.writeURL,
                   writeUnavailableReason: HardwareValidation.allowsDisplayWrites ? nil : HardwareValidation.explanation)
                .safeAreaInset(edge: .top, spacing: 0) { betaNotice("New") }
                .navigationTitle("New")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("New", systemImage: "square.and.pencil") }.tag(0)
            NavigationStack { libraryView.safeAreaInset(edge: .top, spacing: 0) { betaNotice("Library") }.navigationTitle("Library") }
                .tabItem { Label("Library", systemImage: "rectangle.stack") }.tag(1)
            NavigationStack { settingsView.safeAreaInset(edge: .top, spacing: 0) { betaNotice("Settings") }.navigationTitle("Settings") }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .adaptiveTabBarBehavior()
        .tint(Color(red: 0.12, green: 0.38, blue: 0.3))
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .data, defaultFilename: exportName) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importFile(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showSave) {
            TextEntrySheet(title: "Libraryに保存", prompt: "カード名", confirmationTitle: "保存",
                           fieldIdentifier: "library.name", confirmationIdentifier: "library.confirmSave",
                           initialValue: cardName) { name in
                if let savePayload { model.save(savePayload, format: saveFormat, name: name) }
            }
        }
        .sheet(isPresented: $showRename) {
            TextEntrySheet(title: "名称変更", prompt: "カード名", confirmationTitle: "変更",
                           fieldIdentifier: "library.rename", confirmationIdentifier: "library.confirmRename",
                           initialValue: cardName) { name in
                if let renameCard { model.rename(renameCard, to: name) }
            }
        }
        .confirmationDialog("このカードを削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let deleteCard { model.delete(deleteCard) } }
        }
        .alert("確認してください", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { model.nfc.showsProgress }, set: { model.nfc.showsProgress = $0 })) { progressView }
    }

    @ViewBuilder private func betaNotice(_ page: String) -> some View {
        if HardwareValidation.isBetaBuild {
            Text("ベータ試験版 · 書き込み結果のご報告にご協力ください")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 6)
                .background(.regularMaterial)
                .accessibilityIdentifier("distribution.betaNotice.\(page)")
        }
    }

    private var libraryView: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                if model.cards.isEmpty {
                    ContentUnavailableView("カードを保存しましょう", systemImage: "rectangle.stack",
                                           description: Text("Newで作成するか、Androidで書き出したBINをインポートできます。"))
                        .padding(.top, 50)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(model.cards) { card in
                            VStack(alignment: .leading, spacing: 10) {
                                if let image = model.thumbnail(for: card) {
                                    Image(uiImage: image).resizable().interpolation(.none).aspectRatio(296.0 / 128, contentMode: .fit)
                                        .background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .accessibilityLabel("\(card.name)の完成画像")
                                        .accessibilityIdentifier("library.thumbnail.\(card.id.uuidString)")
                                }
                                Text(card.name).font(.headline).lineLimit(2)
                                Text(card.format.title).font(.caption).foregroundStyle(.secondary)
                                LiquidGlassControlGroup {
                                    HStack {
                                        Button("編集", systemImage: "pencil") { model.edit(card) }
                                            .labelStyle(.titleAndIcon)
                                            .adaptiveGlassButtonStyle()
                                            .accessibilityIdentifier("library.edit")
                                        Spacer()
                                        Menu {
                                            Button("NFCに書込", systemImage: "wave.3.right") { model.nfc.writeImage(card.bytes, clean: model.cleanBeforeWrite) }
                                                .disabled(card.format == .gray4 || !HardwareValidation.allowsDisplayWrites)
                                            Button("名称変更", systemImage: "pencil") { renameCard = card; cardName = card.name; showRename = true }
                                            Button("BIN書出", systemImage: "square.and.arrow.up") { export(card.bytes, name: card.name) }
                                            Button("削除", systemImage: "trash", role: .destructive) { deleteCard = card; showDelete = true }
                                        } label: {
                                            Label("その他", systemImage: "ellipsis")
                                                .labelStyle(.iconOnly)
                                                .frame(width: 32, height: 32)
                                        }
                                        .adaptiveGlassButtonStyle()
                                        .accessibilityLabel("\(card.name)の操作")
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5)
                            }
                        }
                    }.padding()
                }
            }
        }
        .toolbar { Button("インポート", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("library.import") }
    }

    private var settingsView: some View { NFCSettingsView(model: model) }
    private var progressView: some View { NFCProgressView(nfc: model.nfc) }
    private func export(_ bytes: Data, name: String) {
        exportFile = NativeBINFile(bytes)
        exportName = name.replacingOccurrences(of: "/", with: "_") + ".bin"
        exporting = true
    }
}
