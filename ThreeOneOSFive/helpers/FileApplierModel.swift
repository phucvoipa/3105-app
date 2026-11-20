import Foundation
import SwiftUI
import UIKit

// MARK: - Presets

enum TargetDestinationPreset: String, CaseIterable, Identifiable {
    case documents
    case preferences
    case library
    case caches
    case root
    case custom

    var id: String { rawValue }

    var relativePath: String {
        switch self {
        case .documents: return "Documents"
        case .preferences: return "Library/Preferences"
        case .library: return "Library"
        case .caches: return "Library/Caches"
        case .root: return ""
        case .custom: return ""
        }
    }

    var displayNameKey: String {
        switch self {
        case .documents: return "apply.preset_documents"
        case .preferences: return "apply.preset_preferences"
        case .library: return "apply.preset_library"
        case .caches: return "apply.preset_caches"
        case .root: return "apply.preset_root"
        case .custom: return "apply.custom_path"
        }
    }

    var systemImage: String {
        switch self {
        case .documents: return "folder.fill"
        case .preferences: return "gearshape.fill"
        case .library: return "books.vertical.fill"
        case .caches: return "archivebox.fill"
        case .root: return "shippingbox.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - Record

struct FileApplierRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let bundleID: String
    let appName: String
    let targetRelativePath: String
    let sourceFileName: String
    let fileSizeBytes: Int64
    let appliedDate: Date
    let backupRelativePath: String?
    let isZipExtraction: Bool
    var isRestored: Bool

    init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String,
        targetRelativePath: String,
        sourceFileName: String,
        fileSizeBytes: Int64,
        appliedDate: Date = Date(),
        backupRelativePath: String? = nil,
        isZipExtraction: Bool = false,
        isRestored: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.targetRelativePath = targetRelativePath
        self.sourceFileName = sourceFileName
        self.fileSizeBytes = fileSizeBytes
        self.appliedDate = appliedDate
        self.backupRelativePath = backupRelativePath
        self.isZipExtraction = isZipExtraction
        self.isRestored = isRestored
    }

    var formattedSize: String {
        if fileSizeBytes <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: appliedDate)
    }
}

// MARK: - History Store

@MainActor
final class FileApplierHistoryStore: ObservableObject {
    static let shared = FileApplierHistoryStore()

    @Published private(set) var records: [FileApplierRecord] = []

    private static let historyFilename = "file_applier_history.json"

    init() {
        load()
    }

    private var historyFileURL: URL? {
        guard let documentsURL = try? PatchWorkspaceService.documentsRootURL() else { return nil }
        let dir = documentsURL.appendingPathComponent("3105/FileApplier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.historyFilename)
    }

    func load() {
        guard let fileURL = historyFileURL,
              let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([FileApplierRecord].self, from: data) {
            records = decoded
        }
    }

    func save() {
        guard let fileURL = historyFileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ record: FileApplierRecord) {
        records.insert(record, at: 0)
        save()
    }

    func markRestored(id: UUID) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].isRestored = true
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    func delete(_ record: FileApplierRecord) {
        records.removeAll(where: { $0.id == record.id })
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }
}

// MARK: - Coordinator

@MainActor
final class FileApplierCoordinator: ObservableObject {
    static let shared = FileApplierCoordinator()

    @Published var pendingSourceURLs: [URL] = []
    @Published var preselectedApp: InstalledApp?

    var hasPendingFile: Bool {
        !pendingSourceURLs.isEmpty
    }

    func prepareIncomingFile(_ url: URL) {
        pendingSourceURLs = [url]
    }

    func clear() {
        pendingSourceURLs.removeAll()
        preselectedApp = nil
    }
}
