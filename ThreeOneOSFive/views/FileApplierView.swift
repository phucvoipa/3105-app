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

struct FileApplierView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var historyStore = FileApplierHistoryStore.shared
    @ObservedObject private var discovery = AppDiscoveryService.shared
    @ObservedObject private var coordinator = FileApplierCoordinator.shared

    @State private var selectedApp: InstalledApp?
    @State private var selectedSourceURLs: [URL] = []
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
        if selectedPreset == .custom {
            return customPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        return selectedPreset.relativePath
    }

    private var canApply: Bool {
        selectedApp != nil && !selectedSourceURLs.isEmpty && !isApplying
    }

    private var hasZipFile: Bool {
        selectedSourceURLs.contains { $0.pathExtension.lowercased() == "zip" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner
                    appSection
                    fileSection
                    destinationSection
                    optionsSection
                    applyButtonSection
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
                language.text("apply.restore_confirm_title"),
                isPresented: $showRestoreConfirmation,
                titleVisibility: .visible,
                presenting: recordToRestore
            ) { record in
                Button(language.text("apply.restore"), role: .destructive) {
                    performRestore(record)
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: { record in
                Text(language.text("apply.restore_confirm_message", record.appName))
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

    // MARK: - App Section

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderLabel(title: language.text("apply.select_app"), systemImage: "app.fill")

            if let app = selectedApp {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        if let icon = app.icon {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.15))
                                Image(systemName: "app.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(AppTheme.accent)
                            }
                            .frame(width: 48, height: 48)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(app.bundleID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            isShowingAppPicker = true
                        } label: {
                            Text(language.text("apply.change_app"))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(AppTheme.accent.opacity(0.12))
                                .foregroundStyle(AppTheme.accent)
                                .clipShape(Capsule())
                        }
                    }

                    Divider()

                    HStack {
                        Button {
                            isShowingContainerBrowser = true
                        } label: {
                            Label(language.text("apply.browse_container"), systemImage: "folder.badge.gearshape")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.accent)
                        }
                        Spacer()
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Button {
                    isShowingAppPicker = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accent.opacity(0.12))
                                .frame(width: 42, height: 42)
                            Image(systemName: "plus.app.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(AppTheme.accent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.text("apply.no_app_selected"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(language.text("apply.select_app"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
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
                                Text(url.lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

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
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderLabel(title: language.text("apply.destination"), systemImage: "folder.fill")

            VStack(alignment: .leading, spacing: 12) {
                // Preset chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TargetDestinationPreset.allCases) { preset in
                            Button {
                                selectedPreset = preset
                                if preset != .custom {
                                    customPath = preset.relativePath
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.systemImage)
                                        .font(.caption)
                                    Text(language.text(preset.displayNameKey))
                                        .font(.subheadline.weight(selectedPreset == preset ? .semibold : .regular))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selectedPreset == preset
                                        ? AppTheme.accent
                                        : Color(uiColor: .tertiarySystemFill)
                                )
                                .foregroundStyle(
                                    selectedPreset == preset
                                        ? Color.white
                                        : Color.primary
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Custom relative path field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đường dẫn tương đối trong container:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("/")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        TextField("Documents hoặc Library/Preferences...", text: $customPath)
                            .font(.subheadline.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: customPath) { _ in
                                if selectedPreset != .custom {
                                    selectedPreset = .custom
                                }
                            }
                    }
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if selectedApp != nil {
                    Button {
                        isShowingContainerBrowser = true
                    } label: {
                        Label(language.text("apply.browse_container"), systemImage: "magnifyingglass")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.accent)
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
        if selectedApp == nil && selectedSourceURLs.isEmpty {
            return "Vui lòng chọn ứng dụng đích và tệp cần áp dụng."
        } else if selectedApp == nil {
            return "Vui lòng chọn ứng dụng đích trước khi áp dụng."
        } else if selectedSourceURLs.isEmpty {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: record.isZipExtraction ? "archivebox.fill" : "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

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

            HStack {
                if record.backupRelativePath != nil {
                    if record.isRestored {
                        Label("Đã khôi phục", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            recordToRestore = record
                            showRestoreConfirmation = true
                        } label: {
                            Label(language.text("apply.restore"), systemImage: "arrow.uturn.backward.circle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }

                Spacer()

                Button {
                    historyStore.delete(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        if let first = urls.first {
            // Auto suggest path
            let ext = first.pathExtension.lowercased()
            if ext == "plist" {
                selectedPreset = .preferences
                customPath = "Library/Preferences"
            } else if ext == "zip" {
                selectedPreset = .documents
                customPath = "Documents"
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
        guard let app = selectedApp, !selectedSourceURLs.isEmpty else { return }
        isApplying = true

        let sources = selectedSourceURLs
        let relDir = effectiveRelativePath
        let backup = autoBackup
        let extract = extractZip

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
                    let msg = language.text(
                        "apply.success_message",
                        fileNames,
                        app.displayName,
                        relDir.isEmpty ? "/" : relDir
                    )
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
            alertNotice = FileApplierNotice(
                title: language.text("apply.restore_success"),
                message: "Đã hoàn tác và ghi lại file gốc vào \(record.appName)."
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
