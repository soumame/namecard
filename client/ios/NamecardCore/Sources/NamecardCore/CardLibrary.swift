import Foundation

public struct LibraryCard: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let format: ImageFormat
    public let createdAt: Date
    public let updatedAt: Date
    public let bytes: Data
}

public enum CardLibraryError: Error, LocalizedError {
    case missingCard
    public var errorDescription: String? { "保存したカードが見つかりません" }
}

/// Store finished BIN images, not editor layers. Call from one serial executor.
/// Atomic metadata writes act as the commit record for each immutable BIN.
public struct CardLibrary: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func list() throws -> [LibraryCard] {
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? read(id: id)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(name: String, format: ImageFormat, bytes: Data) throws -> LibraryCard {
        guard bytes.count == format.byteCount else { throw NativeImageError.invalidByteCount }
        let now = Date()
        let metadata = Metadata(id: UUID(), name: Self.normalizeName(name), format: format, createdAt: now, updatedAt: now)
        try bytes.write(to: binURL(metadata.id), options: .atomic)
        do { try write(metadata) }
        catch { try? FileManager.default.removeItem(at: binURL(metadata.id)); throw error }
        return metadata.card(bytes: bytes)
    }

    public func rename(id: UUID, name: String) throws -> LibraryCard {
        let card = try read(id: id)
        let metadata = Metadata(id: id, name: Self.normalizeName(name), format: card.format, createdAt: card.createdAt, updatedAt: Date())
        try write(metadata)
        return metadata.card(bytes: card.bytes)
    }

    public func delete(id: UUID) throws {
        // Hide the entry first. An interrupted delete may leave an unreferenced
        // BIN, but it cannot leave a visible card pointing at a missing image.
        for url in [metadataURL(id), binURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func read(id: UUID) throws -> LibraryCard {
        guard FileManager.default.fileExists(atPath: metadataURL(id).path) else { throw CardLibraryError.missingCard }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL(id)))
        guard metadata.id == id else { throw CardLibraryError.missingCard }
        let bytes = try Data(contentsOf: binURL(id))
        guard bytes.count == metadata.format.byteCount else { throw NativeImageError.invalidByteCount }
        return metadata.card(bytes: bytes)
    }

    private func write(_ metadata: Metadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL(metadata.id), options: .atomic)
    }
    private func metadataURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func binURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("bin") }
    private static func normalizeName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "名称未設定" : trimmed).prefix(80))
    }

    private struct Metadata: Codable {
        let id: UUID
        let name: String
        let format: ImageFormat
        let createdAt: Date
        let updatedAt: Date
        func card(bytes: Data) -> LibraryCard {
            LibraryCard(id: id, name: name, format: format, createdAt: createdAt, updatedAt: updatedAt, bytes: bytes)
        }
    }
}
