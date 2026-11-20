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
        var path = rawPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
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

    static func guessBundleID(from filename: String, installedApps: [InstalledApp] = []) -> String? {
        let lower = filename.lowercased()
        if lower.contains("ffvn") || lower.contains("freefirevn") || lower.contains("free fire vn") {
            return "com.garena.ffvn"
        }
        if lower.contains("ffmax") || lower.contains("freefiremax") || lower.contains("free fire max") {
            return "com.dts.freefiremax"
        }
        if lower.contains("ffth") || lower.contains("freefireth") {
            return "com.dts.freefireth"
        }
        if lower.contains("pubg") || lower.contains("vng.pubg") {
            return "com.vng.pubgmobile"
        }
        if lower.contains("lqmb") || lower.contains("lienquan") || lower.contains("aov") {
            return "com.garena.game.kgvn"
        }
        for app in installedApps {
            if lower.contains(app.bundleID.lowercased()) || (!app.displayName.isEmpty && lower.contains(app.displayName.lowercased())) {
                return app.bundleID
            }
        }
        return nil
    }

    static func inspectPackage(at url: URL, password: String? = nil, installedApps: [InstalledApp] = []) -> DetectedPackageInspection? {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let guessedBundle = guessBundleID(from: url.lastPathComponent, installedApps: installedApps)

        // 1. Kiểm tra định dạng gói 3105 (3105PATCH)
        let magic = Data("3105PATCH\0".utf8)
        if data.count > magic.count && data.prefix(magic.count) == magic {
            if let summary = try? PatchPackageCodec.inspect(data) {
                var decodedProject: PatchProject?
                if let key = try? PatchKeyStore.load(for: summary) {
                    decodedProject = try? PatchPackageCodec.decode(data, contentKey: key).project
                }
                if decodedProject == nil && !summary.isPasswordProtected {
                    decodedProject = try? PatchPackageCodec.decode(data, password: nil).project
                }
                // Nếu decode tiêu chuẩn thất bại (do kiểm tra nghiêm ngặt author/bundle), dùng decodeLenient
                if decodedProject == nil && !summary.isPasswordProtected {
                    decodedProject = try? PatchPackageCodec.decodeLenient(data, password: nil)
                }
                if decodedProject == nil && summary.isPasswordProtected, let pass = password, !pass.isEmpty {
                    decodedProject = try? PatchPackageCodec.decodeLenient(data, password: pass)
                }

                if let project = decodedProject {
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
                    let bundle = project.allBundleIdentifiers.first ?? guessedBundle
                    return DetectedPackageInspection(
                        payload: .patchProject(project: project),
                        suggestedBundleID: bundle,
                        entries: entries,
                        isPasswordProtected: summary.isPasswordProtected
                    )
                } else if summary.isPasswordProtected {
                    return DetectedPackageInspection(
                        payload: .passwordProtected(packageID: summary.packageID),
                        suggestedBundleID: guessedBundle,
                        entries: [],
                        isPasswordProtected: true
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
            let bundle = project.allBundleIdentifiers.first ?? guessedBundle
            return DetectedPackageInspection(
                payload: .patchProject(project: project),
                suggestedBundleID: bundle,
                entries: entries,
                isPasswordProtected: false
            )
        }

        // 3. Kiểm tra tệp ZIP (hoặc tệp .3105 chứa nội dung ZIP)
        let isZipHeader = data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
        let isZipExt = url.pathExtension.lowercased() == "zip"
        let is3105Ext = url.pathExtension.lowercased() == "3105"
        if isZipHeader || isZipExt || is3105Ext {
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
                    suggestedBundleID: guessedBundle,
                    entries: entries,
                    isPasswordProtected: false
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

        var containerPath = app.containerPath
        if containerPath.isEmpty || !fileManager.fileExists(atPath: containerPath) {
            if let resolved = ContainerStore.resolveAppContainerPath(bundleID: app.bundleID),
               fileManager.fileExists(atPath: resolved) {
                containerPath = resolved
            } else {
                throw FileApplierError.containerNotFound(app.bundleID)
            }
        }

        let effectiveApp = InstalledApp(
            bundleID: app.bundleID,
            name: app.name,
            containerPath: containerPath,
            version: app.version,
            icon: app.icon
        )

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
                        to: effectiveApp,
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
                        bundleID: effectiveApp.bundleID,
                        appName: effectiveApp.displayName,
                        autoBackup: autoBackup,
                        backupRootURL: backupRoot,
                        fileManager: fileManager
                    )
                    for r in createdRecords {
                        totalBytes += r.fileSizeBytes
                    }

                case .passwordProtected:
                    throw FileApplierError.applyFailed("Tệp .3105 này có mật khẩu bảo vệ. Vui lòng mở khóa trước khi áp dụng.")
                }

                // Lưu vào lịch sử
                DispatchQueue.main.async {
                    for record in createdRecords {
                        FileApplierHistoryStore.shared.add(record)
                    }
                }

                let summary = "Đã đưa \(createdRecords.count) tệp từ “\(firstURL.lastPathComponent)” vào đúng các thư mục tương ứng trong \(effectiveApp.displayName)."
                return FileApplierResult(
                    records: createdRecords,
                    totalBytes: totalBytes,
                    summaryMessage: summary
                )
            }

            // Nếu là tệp .3105: Cố gắng giải mã và đưa thẳng vào đúng cấu trúc nội bộ của app
            if firstURL.pathExtension.lowercased() == "3105" {
                if let data = try? Data(contentsOf: firstURL) {
                    if let project = (try? PatchPackageCodec.decodeLenient(data, password: nil))
                        ?? (try? PatchPackageCodec.decode(data, password: nil).project) {
                        createdRecords = try applyPatchProject(
                            project: project,
                            to: effectiveApp,
                            autoBackup: autoBackup,
                            fileManager: fileManager
                        )
                        for r in createdRecords {
                            totalBytes += r.fileSizeBytes
                        }
                        DispatchQueue.main.async {
                            for record in createdRecords {
                                FileApplierHistoryStore.shared.add(record)
                            }
                        }
                        let summary = "Đã đưa \(createdRecords.count) tệp từ “\(firstURL.lastPathComponent)” vào đúng các thư mục tương ứng trong \(effectiveApp.displayName)."
                        return FileApplierResult(
                            records: createdRecords,
                            totalBytes: totalBytes,
                            summaryMessage: summary
                        )
                    }
                }
                throw FileApplierError.applyFailed("Không thể giải mã tệp .3105 này (tệp có thể yêu cầu mật khẩu hoặc không đúng định dạng). Gói .3105 không được sao chép trực tiếp vào Documents.")
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
                    app: effectiveApp,
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
                    app: effectiveApp,
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

        let summary = "Đã áp dụng \(createdRecords.count) mục vào \(effectiveApp.displayName)."
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
