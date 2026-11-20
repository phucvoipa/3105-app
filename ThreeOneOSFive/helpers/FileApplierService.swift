import Foundation
import UIKit

enum FileApplierError: LocalizedError, Equatable {
    case containerNotFound(String)
    case accessDenied(String)
    case sourceMissing
    case cannotCreateDestination
    case backupFailed(String)
    case applyFailed(String)
    case zipExtractionFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .containerNotFound(let bundle):
            return "Không tìm thấy thư mục container cho \(bundle)."
        case .accessDenied(let path):
            return "Không thể cấp quyền truy cập vào container tại \(path)."
        case .sourceMissing:
            return "Không tìm thấy tệp nguồn đã chọn."
        case .cannotCreateDestination:
            return "Không thể tạo thư mục đích trong container."
        case .backupFailed(let msg):
            return "Lỗi sao lưu tệp gốc: \(msg)"
        case .applyFailed(let msg):
            return "Lỗi áp dụng tệp: \(msg)"
        case .zipExtractionFailed(let msg):
            return "Lỗi giải nén tệp ZIP: \(msg)"
        case .restoreFailed(let msg):
            return "Lỗi khôi phục tệp: \(msg)"
        }
    }
}

struct FileApplierResult: Equatable {
    let records: [FileApplierRecord]
    let totalBytes: Int64
    let summaryMessage: String
}

enum FileApplierService {
    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let documents = try PatchWorkspaceService.documentsRootURL(fileManager: fileManager)
        let root = documents.appendingPathComponent("Backups/FileApplier", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func normalizeContainerRelativePath(_ rawPath: String, targetBundleID: String) -> String {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let bundlePrefix = targetBundleID.lowercased() + "/"
        if path.lowercased().hasPrefix(bundlePrefix) {
            path = String(path.dropFirst(bundlePrefix.count))
        }
        if path.lowercased().contains("containers/data/application/") {
            let parts = path.components(separatedBy: "/")
            if let appIndex = parts.firstIndex(where: { $0.lowercased() == "application" }),
               appIndex + 2 < parts.count {
                path = parts[(appIndex + 2)...].joined(separator: "/")
            }
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func inspectPackage(at url: URL) -> DetectedPackageInspection? {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }

        // 1. Kiểm tra định dạng gói 3105 (3105PATCH)
        let magic = Data("3105PATCH\0".utf8)
        if data.count > magic.count && data.prefix(magic.count) == magic {
            if let summary = try? PatchPackageCodec.inspect(data) {
                var decoded: DecodedPatchPackage?
                if let key = try? PatchKeyStore.load(for: summary) {
                    decoded = try? PatchPackageCodec.decode(data, contentKey: key)
                }
                if decoded == nil && !summary.isPasswordProtected {
                    decoded = try? PatchPackageCodec.decode(data, password: nil)
                }
                if let project = decoded?.project {
                    let entries = project.rules.map { rule in
                        PackageEntryItem(
                            targetRelativePath: rule.relativePath,
                            fileName: rule.replacementFilename.isEmpty ? (rule.relativePath as NSString).lastPathComponent : rule.replacementFilename,
                            fileSizeBytes: Int64(rule.replacementData.count),
                            isDirectory: false
                        )
                    } + project.directories.map { dir in
                        PackageEntryItem(
                            targetRelativePath: dir.relativePath,
                            fileName: (dir.relativePath as NSString).lastPathComponent,
                            fileSizeBytes: 0,
                            isDirectory: true
                        )
                    }
                    let bundle = project.allBundleIdentifiers.first
                    return DetectedPackageInspection(
                        payload: .patchProject(project: project),
                        suggestedBundleID: bundle,
                        entries: entries
                    )
                }
            }
        }

        // 2. Kiểm tra định dạng PatchProject raw (PropertyList hoặc JSON)
        if let project = (try? PropertyListDecoder().decode(PatchProject.self, from: data))
            ?? (try? JSONDecoder().decode(PatchProject.self, from: data)) {
            let entries = project.rules.map { rule in
                PackageEntryItem(
                    targetRelativePath: rule.relativePath,
                    fileName: rule.replacementFilename.isEmpty ? (rule.relativePath as NSString).lastPathComponent : rule.replacementFilename,
                    fileSizeBytes: Int64(rule.replacementData.count),
                    isDirectory: false
                )
            } + project.directories.map { dir in
                PackageEntryItem(
                    targetRelativePath: dir.relativePath,
                    fileName: (dir.relativePath as NSString).lastPathComponent,
                    fileSizeBytes: 0,
                    isDirectory: true
                )
            }
            let bundle = project.allBundleIdentifiers.first
            return DetectedPackageInspection(
                payload: .patchProject(project: project),
                suggestedBundleID: bundle,
                entries: entries
            )
        }

        // 3. Kiểm tra tệp ZIP (hoặc tệp .3105 chứa nội dung ZIP)
        let isZipHeader = data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
        let isZipExt = url.pathExtension.lowercased() == "zip"
        if isZipHeader || isZipExt {
            if let zipEntries = try? ZIPArchiveExtractor.inspect(archiveURL: url) {
                let entries = zipEntries.map { entry in
                    PackageEntryItem(
                        targetRelativePath: entry.path,
                        fileName: entry.components.last ?? entry.path,
                        fileSizeBytes: Int64(entry.uncompressedSize),
                        isDirectory: entry.isDirectory
                    )
                }
                return DetectedPackageInspection(
                    payload: .zipArchive(archiveURL: url),
                    suggestedBundleID: nil,
                    entries: entries
                )
            }
        }

        return nil
    }

    static func detectPatchPackage(at url: URL) -> (bundleID: String?, relativePath: String?)? {
        if let inspection = inspectPackage(at: url) {
            let firstPath = inspection.entries.first?.targetRelativePath
            return (inspection.suggestedBundleID, firstPath)
        }
        return nil
    }

    static func apply(
        sourceURLs: [URL],
        to app: InstalledApp,
        destinationRelativeDir: String,
        autoBackup: Bool,
        extractZipIfApplicable: Bool,
        fileManager: FileManager = .default
    ) throws -> FileApplierResult {
        guard !sourceURLs.isEmpty else {
            throw FileApplierError.sourceMissing
        }

        let containerPath = app.containerPath
        guard !containerPath.isEmpty, fileManager.fileExists(atPath: containerPath) else {
            throw FileApplierError.containerNotFound(app.bundleID)
        }

        let accessGrant = ContainerStore.grantContainerAccess(containerPath)
        log("fileapplier: granted container access to \(containerPath), code=\(accessGrant)")

        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        let targetDirectoryURL: URL
        let cleanRelativeDir = destinationRelativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        if cleanRelativeDir.isEmpty {
            targetDirectoryURL = containerURL
        } else {
            targetDirectoryURL = containerURL.appendingPathComponent(cleanRelativeDir, isDirectory: true)
        }

        var createdRecords: [FileApplierRecord] = []
        var totalBytes: Int64 = 0

        // Kiểm tra xem có áp dụng dạng Gói tệp có cấu trúc nội bộ hay không
        if sourceURLs.count == 1, let firstURL = sourceURLs.first {
            let isSecurityScoped = firstURL.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    firstURL.stopAccessingSecurityScopedResource()
                }
            }

            if let inspection = inspectPackage(at: firstURL), inspection.hasInternalPaths {
                switch inspection.payload {
                case .patchProject(let project):
                    createdRecords = try applyPatchProject(
                        project: project,
                        to: app,
                        autoBackup: autoBackup,
                        fileManager: fileManager
                    )
                    for r in createdRecords {
                        totalBytes += r.fileSizeBytes
                    }

                case .zipArchive(let archiveURL):
                    let backupRoot = try backupRootURL(fileManager: fileManager)
                    createdRecords = try ZIPArchiveExtractor.extractEntriesDirectly(
                        archiveURL: archiveURL,
                        into: containerURL,
                        bundleID: app.bundleID,
                        appName: app.displayName,
                        autoBackup: autoBackup,
                        backupRootURL: backupRoot,
                        fileManager: fileManager
                    )
                    for r in createdRecords {
                        totalBytes += r.fileSizeBytes
                    }
                }

                // Lưu vào lịch sử
                DispatchQueue.main.async {
                    for record in createdRecords {
                        FileApplierHistoryStore.shared.add(record)
                    }
                }

                let summary = "Đã đưa \(createdRecords.count) tệp từ “\(firstURL.lastPathComponent)” vào đúng các thư mục tương ứng trong \(app.displayName)."
                return FileApplierResult(
                    records: createdRecords,
                    totalBytes: totalBytes,
                    summaryMessage: summary
                )
            }
        }

        // Trường hợp thông thường: sao chép hoặc giải nén vào thư mục được chọn
        do {
            try fileManager.createDirectory(at: targetDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw FileApplierError.cannotCreateDestination
        }

        for sourceURL in sourceURLs {
            let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw FileApplierError.sourceMissing
            }

            let sourceFileSize = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0

            // If it's a zip file and extract mode is on
            if extractZipIfApplicable && sourceURL.pathExtension.lowercased() == "zip" {
                let zipRecord = try applyZip(
                    sourceURL: sourceURL,
                    targetDirectoryURL: targetDirectoryURL,
                    relativeDir: cleanRelativeDir,
                    app: app,
                    autoBackup: autoBackup,
                    fileManager: fileManager
                )
                createdRecords.append(zipRecord)
                totalBytes += sourceFileSize
            } else {
                let fileRecord = try applySingleFile(
                    sourceURL: sourceURL,
                    targetDirectoryURL: targetDirectoryURL,
                    relativeDir: cleanRelativeDir,
                    app: app,
                    autoBackup: autoBackup,
                    fileManager: fileManager
                )
                createdRecords.append(fileRecord)
                totalBytes += sourceFileSize
            }
        }

        // Add to history store
        DispatchQueue.main.async {
            for record in createdRecords {
                FileApplierHistoryStore.shared.add(record)
            }
        }

        let summary = "Đã áp dụng \(createdRecords.count) mục vào \(app.displayName)."
        return FileApplierResult(
            records: createdRecords,
            totalBytes: totalBytes,
            summaryMessage: summary
        )
    }

    static func applyPatchProject(
        project: PatchProject,
        to app: InstalledApp,
        autoBackup: Bool,
        fileManager: FileManager = .default
    ) throws -> [FileApplierRecord] {
        let containerURL = URL(fileURLWithPath: app.containerPath, isDirectory: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupRoot = try backupRootURL(fileManager: fileManager)
        var records: [FileApplierRecord] = []

        // 1. Tạo các thư mục được khai báo
        for directory in project.directories {
            let relPath = normalizeContainerRelativePath(directory.relativePath, targetBundleID: app.bundleID)
            guard !relPath.isEmpty else { continue }
            let dirURL = containerURL.appendingPathComponent(relPath, isDirectory: true)
            try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        // 2. Ghi đè hoặc thêm mới các tệp theo rules
        for rule in project.rules {
            let relPath = normalizeContainerRelativePath(rule.relativePath, targetBundleID: app.bundleID)
            guard !relPath.isEmpty else { continue }
            let targetFileURL = containerURL.appendingPathComponent(relPath, isDirectory: false)
            let parentDir = targetFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            var backupRelativePath: String?
            if fileManager.fileExists(atPath: targetFileURL.path) && autoBackup {
                let backupSubdir = "\(app.bundleID)/\(timestamp)"
                let backupDir = backupRoot.appendingPathComponent(backupSubdir, isDirectory: true)
                try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let backupFile = backupDir.appendingPathComponent(relPath)
                try fileManager.createDirectory(at: backupFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: backupFile)
                do {
                    try fileManager.copyItem(at: targetFileURL, to: backupFile)
                    backupRelativePath = "\(backupSubdir)/\(relPath)"
                    log("fileapplier: backed up \(targetFileURL.path) to \(backupFile.path)")
                } catch {
                    log("fileapplier: patch auto-backup warning: \(error.localizedDescription)")
                }
            }

            // Ghi dữ liệu thay thế
            let tempFile = parentDir.appendingPathComponent(".3105-patch-\(UUID().uuidString)")
            try rule.replacementData.write(to: tempFile, options: .atomic)
            defer { try? fileManager.removeItem(at: tempFile) }

            if fileManager.fileExists(atPath: targetFileURL.path) {
                _ = try FileReplacementService.replace(target: targetFileURL, with: tempFile, fileManager: fileManager)
                log("fileapplier: replaced file at \(targetFileURL.path)")
            } else {
                try fileManager.moveItem(at: tempFile, to: targetFileURL)
                log("fileapplier: created file at \(targetFileURL.path)")
            }

            let fileName = rule.replacementFilename.isEmpty ? targetFileURL.lastPathComponent : rule.replacementFilename
            let record = FileApplierRecord(
                bundleID: app.bundleID,
                appName: app.displayName,
                targetRelativePath: relPath,
                sourceFileName: fileName,
                fileSizeBytes: Int64(rule.replacementData.count),
                backupRelativePath: backupRelativePath,
                isZipExtraction: false
            )
            records.append(record)
        }

        return records
    }

    private static func applySingleFile(
        sourceURL: URL,
        targetDirectoryURL: URL,
        relativeDir: String,
        app: InstalledApp,
        autoBackup: Bool,
        fileManager: FileManager
    ) throws -> FileApplierRecord {
        let fileName = sourceURL.lastPathComponent
        let targetFileURL = targetDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        let targetRelativePath = relativeDir.isEmpty ? fileName : "\(relativeDir)/\(fileName)"

        var backupRelativePath: String?

        // Check if destination file already exists
        if fileManager.fileExists(atPath: targetFileURL.path) {
            if autoBackup {
                let timestamp = Int(Date().timeIntervalSince1970)
                let backupSubdir = "\(app.bundleID)/\(timestamp)"
                let backupDir = try backupRootURL(fileManager: fileManager).appendingPathComponent(backupSubdir, isDirectory: true)
                try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let backupFile = backupDir.appendingPathComponent(fileName)
                try? fileManager.removeItem(at: backupFile)
                do {
                    try fileManager.copyItem(at: targetFileURL, to: backupFile)
                    backupRelativePath = "\(backupSubdir)/\(fileName)"
                    log("fileapplier: backed up \(targetFileURL.path) to \(backupFile.path)")
                } catch {
                    log("fileapplier: auto-backup warning: \(error.localizedDescription)")
                }
            }

            // Replace existing file using FileReplacementService to preserve permissions
            do {
                _ = try FileReplacementService.replace(target: targetFileURL, with: sourceURL, fileManager: fileManager)
                log("fileapplier: successfully replaced file at \(targetFileURL.path)")
            } catch {
                throw FileApplierError.applyFailed(error.localizedDescription)
            }
        } else {
            // New file: copy directly
            do {
                try fileManager.copyItem(at: sourceURL, to: targetFileURL)
                log("fileapplier: copied new file to \(targetFileURL.path)")
            } catch {
                throw FileApplierError.applyFailed(error.localizedDescription)
            }
        }

        let size = (try? fileManager.attributesOfItem(atPath: targetFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        return FileApplierRecord(
            bundleID: app.bundleID,
            appName: app.displayName,
            targetRelativePath: targetRelativePath,
            sourceFileName: fileName,
            fileSizeBytes: size,
            backupRelativePath: backupRelativePath,
            isZipExtraction: false
        )
    }

    private static func applyZip(
        sourceURL: URL,
        targetDirectoryURL: URL,
        relativeDir: String,
        app: InstalledApp,
        autoBackup: Bool,
        fileManager: FileManager
    ) throws -> FileApplierRecord {
        let fileName = sourceURL.lastPathComponent

        // Extract ZIP
        do {
            let result = try ZIPArchiveExtractor.extract(archiveURL: sourceURL, into: targetDirectoryURL, fileManager: fileManager)
            log("fileapplier: extracted \(result.fileCount) items from \(fileName) into \(targetDirectoryURL.path)")
        } catch {
            throw FileApplierError.zipExtractionFailed(error.localizedDescription)
        }

        let size = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        return FileApplierRecord(
            bundleID: app.bundleID,
            appName: app.displayName,
            targetRelativePath: relativeDir.isEmpty ? "/" : relativeDir,
            sourceFileName: fileName,
            fileSizeBytes: size,
            backupRelativePath: nil,
            isZipExtraction: true
        )
    }

    static func restore(
        record: FileApplierRecord,
        customContainerPath: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let containerPath: String
        if let custom = customContainerPath, !custom.isEmpty {
            containerPath = custom
        } else if let resolved = ContainerStore.resolveAppContainerPath(bundleID: record.bundleID) {
            containerPath = resolved
        } else {
            throw FileApplierError.containerNotFound(record.bundleID)
        }

        _ = ContainerStore.grantContainerAccess(containerPath)

        let targetFileURL = URL(fileURLWithPath: containerPath).appendingPathComponent(record.targetRelativePath)

        if let backupRelPath = record.backupRelativePath {
            // Trường hợp 1: Có bản sao lưu file gốc cũ -> Khôi phục đè lại file gốc
            let backupRoot = try backupRootURL(fileManager: fileManager)
            let backupFileURL = backupRoot.appendingPathComponent(backupRelPath)

            guard fileManager.fileExists(atPath: backupFileURL.path) else {
                throw FileApplierError.restoreFailed("Tệp sao lưu không còn tồn tại trên máy.")
            }

            if fileManager.fileExists(atPath: targetFileURL.path) {
                _ = try FileReplacementService.replace(target: targetFileURL, with: backupFileURL, fileManager: fileManager)
            } else {
                try fileManager.createDirectory(at: targetFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: backupFileURL, to: targetFileURL)
            }
            log("fileapplier: restored original backup for \(record.targetRelativePath)")
        } else {
            // Trường hợp 2: Tệp mod mới thêm vào -> Xóa tệp mod để đưa game về nguyên trạng ban đầu
            if fileManager.fileExists(atPath: targetFileURL.path) {
                try fileManager.removeItem(at: targetFileURL)
                log("fileapplier: removed newly added mod file at \(targetFileURL.path)")
            }
        }

        DispatchQueue.main.async {
            FileApplierHistoryStore.shared.markRestored(id: record.id)
        }
    }
}
