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

    static func detectPatchPackage(at url: URL) -> (bundleID: String?, relativePath: String?)? {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? PatchPackageCodec.decode(data, password: nil) else {
            return nil
        }
        let project = decoded.project
        let targetBundle = project.allBundleIdentifiers.first
        let targetPath = project.rules.first?.relativePath ?? project.directories.first?.relativePath
        return (targetBundle, targetPath)
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

        do {
            try fileManager.createDirectory(at: targetDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw FileApplierError.cannotCreateDestination
        }

        var createdRecords: [FileApplierRecord] = []
        var totalBytes: Int64 = 0

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
