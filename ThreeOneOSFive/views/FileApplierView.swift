import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileApplierNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let isError: Bool

    init(title: String, message: String, isError: Bool = false) {
        self.title = title
        self.message = message
        self.isError = isError
    }
}

@MainActor
struct FileApplierView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var historyStore = FileApplierHistoryStore.shared
    @ObservedObject private var discovery = AppDiscoveryService.shared
    @ObservedObject private var coordinator = FileApplierCoordinator.shared

    @State private var selectedApp: InstalledApp?
    @State private var selectedSourceURLs: [URL] = []
    @State private var packageInspection: DetectedPackageInspection?
    @State private var packagePassword: String = ""
    @State private var selectedPreset: TargetDestinationPreset = .documents
    @State private var customPath: String = ""
    @State private var autoBackup: Bool = true
    @State private var extractZip: Bool = true

    @State private var isShowingDocumentPicker = false
    @State private var isShowingAppPicker = false
    @State private var isShowingContainerBrowser = false
    @State private var isApplying = false
    @State private var alertNotice: FileApplierNotice?

    @State private var recordToRestore: FileApplierRecord?
    @State private var showRestoreConfirmation = false

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
    }

    private var effectiveRelativePath: String {
        let trimmed = customPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !trimmed.isEmpty {
            return trimmed
        }
        return selectedPreset.relativePath
    }

    private var canApply: Bool {
        !selectedSourceURLs.isEmpty && !isApplying
    }

    private var hasZipFile: Bool {
        selectedSourceURLs.contains { $0.pathExtension.lowercased() == "zip" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner
                    fileSection
                    if !selectedSourceURLs.isEmpty {
                        destinationSection
                        optionsSection
                        applyButtonSection
                    }
                    historySection
                }
                .padding(.horizontal, AppTheme.pageInset)
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(language.text("apply.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        discovery.load(force: true)
                    } label: {
                        if discovery.isResolving {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(discovery.isResolving)
                    .accessibilityLabel(language.text("browser.retry"))
                }

                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .sheet(isPresented: $isShowingDocumentPicker) {
                FileDocumentPicker(
                    allowedContentTypes: [.item, .data],
                    copiesSelectedDocument: true,
                    allowsMultipleSelection: true,
                    onSelection: { result in
                        switch result {
                        case .success(let urls):
                            handleFileSelection(urls)
                        case .failure(let error):
                            log("fileapplier: document picker failed: \(error.localizedDescription)")
                        }
                    },
                    onCancel: {}
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $isShowingAppPicker) {
                AppPickerSheet(
                    apps: discovery.apps,
                    isLoading: discovery.isLoading,
                    onSelect: { app in
                        selectedApp = app
                        isShowingAppPicker = false
                    },
                    onDismiss: { isShowingAppPicker = false }
                )
            }
            .sheet(isPresented: $isShowingContainerBrowser) {
                if let app = selectedApp {
                    AppContainerPickerSheet(
                        app: app,
                        onSelectFolder: { relativePath in
                            selectedPreset = .custom
                            customPath = relativePath
                            isShowingContainerBrowser = false
                        },
                        onSelectFile: { relativeFilePath in
                            selectedPreset = .custom
                            customPath = (relativeFilePath as NSString).deletingLastPathComponent
                            isShowingContainerBrowser = false
                        },
                        onDismiss: { isShowingContainerBrowser = false }
                    )
                }
            }
            .alert(item: $alertNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(language.text("common.done")))
                )
            }
            .confirmationDialog(
                "Khôi phục trạng thái ban đầu",
                isPresented: $showRestoreConfirmation,
                titleVisibility: .visible,
                presenting: recordToRestore
            ) { record in
                Button(
                    record.backupRelativePath != nil ? "Khôi phục file gốc" : "Gỡ bỏ file đã áp dụng",
                    role: .destructive
                ) {
                    performRestore(record)
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: { record in
                if record.backupRelativePath != nil {
                    Text("Hệ thống sẽ ghi đè lại file gốc ban đầu vào \(record.appName).")
                } else {
                    Text("Hệ thống sẽ xóa file “\(record.sourceFileName)” khỏi thư mục của \(record.appName) để đưa game về nguyên trạng.")
                }
            }
            .onAppear {
                discovery.load(force: false)
                consumeIncomingCoordinatorFiles()
            }
            .onChange(of: coordinator.pendingSourceURLs) { urls in
                if !urls.isEmpty {
                    handleFileSelection(urls)
                    coordinator.clear()
                }
            }
        }
    }

    // MARK: - Banner

    private var headerBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(language.text("apply.title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(language.text("apply.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - File Section

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderLabel(title: language.text("apply.select_file"), systemImage: "doc.fill")

            if !selectedSourceURLs.isEmpty {
                VStack(spacing: 12) {
                    ForEach(selectedSourceURLs, id: \.path) { url in
                        HStack(spacing: 12) {
                            Image(systemName: url.pathExtension.lowercased() == "zip" ? "archivebox.fill" : "doc.text.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let inspection = packageInspection, inspection.hasInternalPaths {
                                        Text("Cấu trúc nội bộ")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(AppTheme.accent.opacity(0.15))
                                            .foregroundStyle(AppTheme.accent)
                                            .clipShape(Capsule())
                                    }
                                }

                                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }

                    if hasZipFile {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label(language.text("apply.zip_detected"), systemImage: "archivebox")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $extractZip) {
                                Text(language.text("apply.zip_extract_mode")).tag(true)
                                Text(language.text("apply.zip_copy_mode")).tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Divider()

                    HStack {
                        Button {
                            isShowingDocumentPicker = true
                        } label: {
                            Label(language.text("apply.change_file"), systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.accent)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            selectedSourceURLs.removeAll()
                            packageInspection = nil
                        } label: {
                            Label(language.text("common.delete"), systemImage: "trash")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Button {
                    isShowingDocumentPicker = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(AppTheme.accent)
                        Text(language.text("apply.choose_from_files"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Hỗ trợ .plist, .json, .zip, .dat, .txt, .bytes, hình ảnh...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppTheme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Destination Section

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeaderLabel(title: "Thông tin cài đặt & Đích đến", systemImage: "arrow.triangle.turn.up.right.diamond.fill")

            VStack(alignment: .leading, spacing: 14) {
                // 1. Ứng dụng mục tiêu (Tự động nhận diện)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ứng dụng được áp dụng:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let app = selectedApp {
                        HStack(spacing: 12) {
                            if let icon = app.icon {
                                Image(uiImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(AppTheme.accent.opacity(0.15))
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(AppTheme.accent)
                                }
                                .frame(width: 40, height: 40)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(app.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Tự động")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                                Text(app.bundleID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                isShowingAppPicker = true
                            } label: {
                                Text("Đổi")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(uiColor: .tertiarySystemFill))
                                    .foregroundStyle(AppTheme.accent)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Button {
                            isShowingAppPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.app.fill")
                                    .foregroundStyle(AppTheme.accent)
                                Text("Chạm để chọn ứng dụng...")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // 2. Vị trí & Đường dẫn đích
                let isPackage = packageInspection != nil
                    || selectedSourceURLs.first?.pathExtension.lowercased() == "3105"
                    || selectedSourceURLs.first?.pathExtension.lowercased() == "zip"
                if isPackage {
                    // Cấu trúc gói tự động
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(AppTheme.accent)
                            Text("Tự động đi theo đường dẫn bên trong tệp")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("Tự động")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }

                        if let inspection = packageInspection, !inspection.entries.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(Array(inspection.entries.prefix(6))) { entry in
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text.fill")
                                            .font(.caption2)
                                            .foregroundStyle(entry.isDirectory ? Color.orange : AppTheme.accent)

                                        Text(entry.targetRelativePath)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(entry.formattedSize)
                                            .font(.system(size: 10).monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }

                                if inspection.entries.count > 6 {
                                    Text("+ \(inspection.entries.count - 6) mục khác trong tệp")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(8)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if let inspection = packageInspection, inspection.isPasswordProtected && inspection.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Tệp .3105 này có mật khẩu bảo vệ", systemImage: "lock.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.orange)
                                HStack {
                                    SecureField("Nhập mật khẩu tệp...", text: $packagePassword)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Mở khóa") {
                                        unlockPackage()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // Preview đích đến
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                                .padding(.top, 2)

                            let appNameText = selectedApp?.displayName ?? selectedApp?.bundleID ?? "[Chưa chọn App]"
                            Text("\(appNameText) ➔ (Tự động đưa từng tệp con vào đúng thư mục bên trong)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } else {
                    // Tệp đơn lẻ thông thường
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chọn thư mục đích trong container:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TargetDestinationPreset.allCases) { preset in
                                    Button {
                                        selectedPreset = preset
                                        customPath = preset.relativePath
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: preset.systemImage)
                                                .font(.caption)
                                            Text(language.text(preset.displayNameKey))
                                                .font(.subheadline.weight(selectedPreset == preset ? .semibold : .regular))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(selectedPreset == preset ? AppTheme.accent : Color(uiColor: .tertiarySystemFill))
                                        .foregroundStyle(selectedPreset == preset ? Color.white : Color.primary)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Preview đích đến
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(AppTheme.accent)
                                .font(.subheadline)
                                .padding(.top, 2)

                            let appNameText = selectedApp?.displayName ?? "[Chưa chọn App]"
                            let targetFolder = effectiveRelativePath.isEmpty ? "(Thư mục gốc)" : effectiveRelativePath
                            let fileNames = selectedSourceURLs.map(\.lastPathComponent).joined(separator: ", ")
                            Text("\(appNameText) ➔ / \(targetFolder) / \(fileNames)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderLabel(title: language.text("apply.options"), systemImage: "slider.horizontal.3")

            VStack(spacing: 12) {
                Toggle(isOn: $autoBackup) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("apply.auto_backup"))
                            .font(.subheadline.weight(.semibold))
                        Text(language.text("apply.auto_backup_desc"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(AppTheme.accent)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Apply Button

    private var applyButtonSection: some View {
        VStack(spacing: 8) {
            Button {
                executeApply()
            } label: {
                HStack(spacing: 8) {
                    if isApplying {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.headline)
                    }
                    Text(isApplying ? language.text("apply.applying") : language.text("apply.action_button"))
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(canApply ? AppTheme.accent : Color.gray.opacity(0.35))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canApply)

            if !canApply && !isApplying {
                Text(validationHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var validationHint: String {
        if selectedSourceURLs.isEmpty {
            return "Vui lòng chọn ít nhất một tệp để áp dụng."
        }
        return ""
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeaderLabel(title: language.text("apply.history_title"), systemImage: "clock.arrow.circlepath")
                Spacer()
                if !historyStore.records.isEmpty {
                    Button(language.text("common.clear")) {
                        historyStore.clearAll()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if historyStore.records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("apply.history_empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(historyStore.records) { record in
                        historyRow(record)
                    }
                }
            }
        }
    }

    private func historyRow(_ record: FileApplierRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: record.isZipExtraction ? "archivebox.fill" : "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.appName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if record.backupRelativePath != nil {
                            Text("Đã sao lưu gốc")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        } else {
                            Text("Tệp mới thêm")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(record.targetRelativePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(record.formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(record.formattedSize)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                if record.isRestored {
                    Label(
                        record.backupRelativePath != nil ? "Đã khôi phục file gốc" : "Đã gỡ bỏ file mod",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                } else {
                    Button {
                        recordToRestore = record
                        showRestoreConfirmation = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                            Text(record.backupRelativePath != nil ? "Khôi phục file gốc" : "Gỡ bỏ file (Khôi phục gốc)")
                        }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.accent.opacity(0.15))
                        .foregroundStyle(AppTheme.accent)
                        .clipShape(Capsule())
                    }
                }

                Spacer()

                Button {
                    historyStore.delete(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Actions

    private func sectionHeaderLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func handleFileSelection(_ urls: [URL]) {
        selectedSourceURLs = urls
        packageInspection = nil
        guard let first = urls.first else { return }

        // 1. Phân tích gói tệp (thử giải mã theo mọi định dạng .3105 / ZIP / Project)
        let inspection = FileApplierService.inspectPackage(
            at: first,
            password: packagePassword.isEmpty ? nil : packagePassword,
            installedApps: discovery.apps
        )
        packageInspection = inspection

        // 2. Tự động nhận diện ứng dụng đích từ gói hoặc từ tên tệp
        let targetBundle = inspection?.suggestedBundleID
            ?? FileApplierService.guessBundleID(from: first.lastPathComponent, installedApps: discovery.apps)

        if let bundle = targetBundle, !bundle.isEmpty {
            autoSelectApp(bundleID: bundle)
        }

        // 3. Nếu là file .3105: Luôn đảm bảo là package, không bao giờ rơi về copy Documents
        if first.pathExtension.lowercased() == "3105" && packageInspection == nil {
            let bundleID = targetBundle ?? "com.garena.ffvn"
            packageInspection = DetectedPackageInspection(
                payload: .patchProject(project: PatchProject(name: (first.lastPathComponent as NSString).deletingPathExtension, rules: [])),
                suggestedBundleID: bundleID,
                entries: [],
                isPasswordProtected: false
            )
            if selectedApp == nil {
                autoSelectApp(bundleID: bundleID)
            }
        }
    }

    private func autoSelectApp(bundleID: String) {
        if let found = discovery.apps.first(where: { $0.bundleID.lowercased() == bundleID.lowercased() }) {
            selectedApp = found
        } else {
            let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID) ?? ""
            let name = bundleID == "com.garena.ffvn" ? "Free Fire VN" : (bundleID == "com.dts.freefiremax" ? "Free Fire MAX" : bundleID)
            selectedApp = InstalledApp(
                bundleID: bundleID,
                name: name,
                containerPath: path,
                version: "",
                icon: nil
            )
        }
    }

    private func unlockPackage() {
        guard let first = selectedSourceURLs.first else { return }
        if let inspection = FileApplierService.inspectPackage(
            at: first,
            password: packagePassword,
            installedApps: discovery.apps
        ) {
            packageInspection = inspection
            if let targetBundle = inspection.suggestedBundleID {
                autoSelectApp(bundleID: targetBundle)
            }
        }
    }

    private func consumeIncomingCoordinatorFiles() {
        if !coordinator.pendingSourceURLs.isEmpty {
            handleFileSelection(coordinator.pendingSourceURLs)
            coordinator.clear()
        }
    }

    private func executeApply() {
        var targetApp = selectedApp
        if targetApp == nil, let first = selectedSourceURLs.first {
            let guessed = packageInspection?.suggestedBundleID
                ?? FileApplierService.guessBundleID(from: first.lastPathComponent, installedApps: discovery.apps)
                ?? "com.garena.ffvn"
            autoSelectApp(bundleID: guessed)
            targetApp = selectedApp
        }
        guard let app = targetApp, !selectedSourceURLs.isEmpty else {
            isShowingAppPicker = true
            return
        }
        isApplying = true

        let sources = selectedSourceURLs
        let relDir = effectiveRelativePath
        let backup = autoBackup
        let extract = extractZip
        let isPackage = packageInspection?.hasInternalPaths == true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try FileApplierService.apply(
                    sourceURLs: sources,
                    to: app,
                    destinationRelativeDir: relDir,
                    autoBackup: backup,
                    extractZipIfApplicable: extract
                )

                DispatchQueue.main.async {
                    self.isApplying = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    let fileNames = sources.map(\.lastPathComponent).joined(separator: ", ")
                    let msg: String
                    if isPackage {
                        msg = "Đã áp dụng thành công \(result.records.count) tệp từ “\(fileNames)” vào đúng các thư mục tương ứng trong \(app.displayName)!\n\n💡 Vui lòng vuốt tắt ứng dụng trong đa nhiệm (App Switcher) rồi mở lại để áp dụng thay đổi."
                    } else {
                        msg = language.text(
                            "apply.success_message",
                            fileNames,
                            app.displayName,
                            relDir.isEmpty ? "/" : relDir
                        )
                    }
                    self.alertNotice = FileApplierNotice(
                        title: language.text("apply.success_title"),
                        message: msg
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.isApplying = false
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.alertNotice = FileApplierNotice(
                        title: language.text("apply.error_title"),
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    private func performRestore(_ record: FileApplierRecord) {
        do {
            try FileApplierService.restore(record: record)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let msg = record.backupRelativePath != nil
                ? "Đã khôi phục thành công file gốc vào \(record.appName).\n\n💡 Vui lòng vuốt tắt game trong đa nhiệm (App Switcher) rồi mở lại."
                : "Đã gỡ bỏ file mod thành công khỏi \(record.appName).\n\n💡 Vui lòng vuốt tắt game trong đa nhiệm (App Switcher) rồi mở lại."
            alertNotice = FileApplierNotice(
                title: "Khôi phục thành công",
                message: msg
            )
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            alertNotice = FileApplierNotice(
                title: language.text("apply.restore_failed"),
                message: error.localizedDescription,
                isError: true
            )
        }
    }
}

// MARK: - App Picker Sheet

@MainActor
struct AppPickerSheet: View {
    @Environment(\.appLanguage) private var language
    let apps: [InstalledApp]
    let isLoading: Bool
    let onSelect: (InstalledApp) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var customBundleID = ""
    @State private var showCustomEntry = false

    private var filteredApps: [InstalledApp] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("apply.app_search_placeholder"),
                    clearLabel: language.text("common.clear")
                )
                Divider()

                List {
                    Section {
                        Button {
                            showCustomEntry.toggle()
                        } label: {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(AppTheme.accent)
                                Text(language.text("apply.custom_bundle_id"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: showCustomEntry ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if showCustomEntry {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField(language.text("apply.custom_bundle_placeholder"), text: $customBundleID)
                                    .font(.caption.monospaced())
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Button {
                                    let cleanID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !cleanID.isEmpty {
                                        let path = ContainerStore.resolveAppContainerPath(bundleID: cleanID) ?? ""
                                        let customApp = InstalledApp(
                                            bundleID: cleanID,
                                            name: cleanID,
                                            containerPath: path,
                                            version: "",
                                            icon: nil
                                        )
                                        onSelect(customApp)
                                    }
                                } label: {
                                    Text(language.text("common.done"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(AppTheme.accent)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                                .disabled(customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }

                    Section {
                        if isLoading && apps.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else if filteredApps.isEmpty {
                            Text(language.text("browser.no_results"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredApps) { app in
                                Button {
                                    onSelect(app)
                                } label: {
                                    HStack(spacing: 12) {
                                        if let icon = app.icon {
                                            Image(uiImage: icon)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 36, height: 36)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        } else {
                                            Image(systemName: "app.fill")
                                                .font(.system(size: 24))
                                                .foregroundStyle(AppTheme.accent)
                                                .frame(width: 36, height: 36)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.displayName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(app.bundleID)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(language.text("apply.select_app"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.close"), action: onDismiss)
                }
            }
        }
    }
}

// MARK: - App Container Picker Sheet

@MainActor
struct AppContainerPickerSheet: View {
    @Environment(\.appLanguage) private var language
    let app: InstalledApp
    let onSelectFolder: (String) -> Void
    let onSelectFile: (String) -> Void
    let onDismiss: () -> Void

    @State private var currentPath: String
    @State private var entries: [FileEntry] = []
    @State private var pathHistory: [String] = []

    init(
        app: InstalledApp,
        onSelectFolder: @escaping (String) -> Void,
        onSelectFile: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.app = app
        self.onSelectFolder = onSelectFolder
        self.onSelectFile = onSelectFile
        self.onDismiss = onDismiss
        _currentPath = State(initialValue: app.containerPath)
    }

    private var relativePath: String {
        let base = app.containerPath
        guard currentPath.hasPrefix(base) else { return "/" }
        let rel = String(currentPath.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? "/" : rel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Breadcrumb path header
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(AppTheme.accent)
                    Text(relativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemFill))

                Divider()

                List {
                    if pathHistory.count > 0 {
                        Button {
                            if let prev = pathHistory.popLast() {
                                currentPath = prev
                                loadEntries()
                            }
                        } label: {
                            Label(".. (Thư mục cha)", systemImage: "arrow.uturn.backward")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            Button {
                                pathHistory.append(currentPath)
                                currentPath = entry.path
                                loadEntries()
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(AppTheme.accent)
                                    Text(entry.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } else {
                            Button {
                                let rel = relativeFilePath(for: entry.path)
                                onSelectFile(rel)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(entry.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(entry.sizeText)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Footer select button
                VStack(spacing: 6) {
                    Button {
                        let rel = relativePath == "/" ? "" : relativePath
                        onSelectFolder(rel)
                    } label: {
                        Text("✅ Chọn thư mục: \(relativePath)")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(AppTheme.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
            }
            .navigationTitle(app.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.close"), action: onDismiss)
                }
            }
            .onAppear {
                _ = ContainerStore.grantContainerAccess(app.containerPath)
                loadEntries()
            }
        }
    }

    private func relativeFilePath(for fullPath: String) -> String {
        let base = app.containerPath
        guard fullPath.hasPrefix(base) else { return fullPath }
        return String(fullPath.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func loadEntries() {
        entries = ContainerStore.listFiles(at: currentPath)
    }
}
