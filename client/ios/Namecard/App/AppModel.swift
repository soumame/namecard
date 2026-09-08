import Foundation
import NamecardCore
import Observation

@MainActor @Observable
final class AppModel {
    let editor = EditorModel()
    let nfc: NFCService
    var cards: [LibraryCard] = []
    var selectedTab = 0
    var cleanBeforeWrite = true
    var errorMessage: String?
    @ObservationIgnored private var library: CardLibrary?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("-ui-testing") ? "NamecardUITesting" : "Namecard", isDirectory: true)
        nfc = NFCService(directory: base)
        do {
            library = try CardLibrary(directoryURL: base.appendingPathComponent("card-library", isDirectory: true))
            reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func reload() {
        let trace = PerformanceTrace.begin("Library.reload")
        defer { PerformanceTrace.end(trace) }
        do { cards = try library?.list() ?? [] }
        catch { errorMessage = error.localizedDescription }
    }
    func save(_ data: Data, format: ImageFormat, name: String) {
        let trace = PerformanceTrace.begin("Library.save")
        defer { PerformanceTrace.end(trace) }
        do {
            guard let library else { throw AppFailure("Libraryを開けません。") }
            _ = try library.save(name: name, format: format, bytes: data)
            reload()
            selectedTab = 1
        } catch { errorMessage = error.localizedDescription }
    }
    func rename(_ card: LibraryCard, to name: String) {
        do { _ = try library?.rename(id: card.id, name: name); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    func delete(_ card: LibraryCard) {
        do { try library?.delete(id: card.id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    func edit(_ card: LibraryCard) {
        do { try editor.load(data: card.bytes, format: card.format); selectedTab = 0 }
        catch { errorMessage = error.localizedDescription }
    }
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize { _ = try NativeImage.format(byteCount: size) }
            let data = try Data(contentsOf: url)
            let format = try NativeImage.format(byteCount: data.count)
            save(data, format: format, name: url.deletingPathExtension().lastPathComponent)
        } catch { errorMessage = error.localizedDescription }
    }
}
