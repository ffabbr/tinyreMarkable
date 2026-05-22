import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var rootMenu: NSMenu!
    private let client = RMClient()

    /// Cache of children per folder path, so submenus aren't re-fetched on every open.
    private var childCache: [String: [RMItem]] = [:]
    /// Folder paths whose submenus have been populated once.
    private var populated: Set<NSMenu> = []
    /// Cache of already-downloaded (but not-yet-rendered) documents per remote path,
    /// so repeated page exports reuse one download and render only what's needed.
    private var preparedCache: [String: PreparedDocument] = [:]
    /// Temp directory backing each cached prepared document (kept alive for re-render).
    private var prepareDirs: [String: URL] = [:]

    /// In-menubar busy indicator (indeterminate bar, shown in the status item button).
    private var busyIndicator: NSProgressIndicator?
    private var busyDepth: Int = 0
    private var idleImage: NSImage?

    /// The currently running cancellable operation, and the Cancel items shown while busy.
    private var currentTask: Task<Void, Never>?
    private var cancelMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? client.bootstrapAuthIfNeeded()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = Self.makeStatusItemImage()
            button.image = image
            self.idleImage = image
        }
        self.statusItem = statusItem

        rebuildRootMenu()
    }

    /// The reMarkable logo, rendered from its SVG path as a template image so the
    /// menu bar tints it correctly for light/dark appearances.
    private static func makeStatusItemImage() -> NSImage {
        // SVG viewBox is 0 0 16 16 (y-down); a flipped image lets us use the SVG
        // coordinates verbatim.
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let path = NSBezierPath()

            // Upper-right "fold".
            path.move(to: NSPoint(x: 8, y: 8))
            path.curve(to: NSPoint(x: 12.1435, y: 6.4616),
                       controlPoint1: NSPoint(x: 8.82048, y: 7.2616),
                       controlPoint2: NSPoint(x: 10.6051, y: 6.4616))
            path.curve(to: NSPoint(x: 16, y: 8),
                       controlPoint1: NSPoint(x: 13.4154, y: 6.4616),
                       controlPoint2: NSPoint(x: 14.7486, y: 6.91296))
            path.line(to: NSPoint(x: 16, y: 0.43072))
            path.curve(to: NSPoint(x: 13.7026, y: 0),
                       controlPoint1: NSPoint(x: 15.2205, y: 0.14352),
                       controlPoint2: NSPoint(x: 14.441, y: 0))
            path.curve(to: NSPoint(x: 8, y: 7.87696),
                       controlPoint1: NSPoint(x: 10.5846, y: 0),
                       controlPoint2: NSPoint(x: 8, y: 2.56416))
            path.line(to: NSPoint(x: 8, y: 8))
            path.close()

            // Lower-left triangle.
            path.move(to: NSPoint(x: 8, y: 16))
            path.line(to: NSPoint(x: 8, y: 8))
            path.line(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: 8))
            path.line(to: NSPoint(x: 8, y: 16))
            path.close()

            // Shrink the glyph slightly within the 16×16 canvas so it reads a touch
            // smaller in the menu bar, keeping it centered.
            let scale: CGFloat = 0.85
            let inset = 16 * (1 - scale) / 2
            let transform = NSAffineTransform()
            transform.translateX(by: inset, yBy: inset)
            transform.scale(by: scale)
            path.transform(using: transform as AffineTransform)

            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu construction

    private func rebuildRootMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        configureFolderMenu(menu, path: "/", isRoot: true)
        rootMenu = menu
        statusItem.menu = menu
    }

    /// Wire a (possibly empty) NSMenu to act as the menu for the given folder path.
    /// Populates on first open via NSMenuDelegate.menuNeedsUpdate.
    private func configureFolderMenu(_ menu: NSMenu, path: String, isRoot: Bool) {
        menu.autoenablesItems = false
        menu.delegate = self
        objc_setAssociatedObject(menu, &AssociatedKeys.folderPath, path, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(menu, &AssociatedKeys.isRoot, isRoot, .OBJC_ASSOCIATION_RETAIN)
    }

    private func populateFolderMenu(_ menu: NSMenu) {
        let path = objc_getAssociatedObject(menu, &AssociatedKeys.folderPath) as? String ?? "/"
        let isRoot = objc_getAssociatedObject(menu, &AssociatedKeys.isRoot) as? Bool ?? false

        menu.removeAllItems()

        // Not signed in: offer the one-time-code pairing flow instead of a (doomed) listing.
        if isRoot && !client.isAuthenticated {
            let signIn = NSMenuItem(title: "Sign in to reMarkable…", action: #selector(signInAction(_:)), keyEquivalent: "")
            signIn.target = self
            signIn.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
            menu.addItem(signIn)
            menu.addItem(.separator())

            let hint = NSMenuItem(title: "Not signed in", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)

            let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)
            return
        }

        // Top: upload to this folder
        let upload = NSMenuItem(
            title: "Upload PDF to \(path)…",
            action: #selector(uploadAction(_:)),
            keyEquivalent: ""
        )
        upload.target = self
        upload.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        upload.representedObject = path
        menu.addItem(upload)
        menu.addItem(.separator())

        // Loading placeholder while we fetch
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)

        // Fetch (use cache if available)
        if let cached = childCache[path] {
            insertChildren(cached, into: menu, parentPath: path, isRoot: isRoot, loadingPlaceholder: loading)
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let items = try await self.client.list(path: path)
                    self.childCache[path] = items
                    if menu.items.contains(loading) {
                        self.insertChildren(items, into: menu, parentPath: path, isRoot: isRoot, loadingPlaceholder: loading)
                    }
                } catch {
                    self.client.lastError = error.localizedDescription
                    if menu.items.contains(loading) {
                        loading.title = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func insertChildren(_ items: [RMItem], into menu: NSMenu, parentPath: String, isRoot: Bool, loadingPlaceholder: NSMenuItem) {
        if menu.items.contains(loadingPlaceholder) {
            menu.removeItem(loadingPlaceholder)
        }

        if items.isEmpty {
            let empty = NSMenuItem(title: "(empty)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for item in items {
            let menuItem = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
            switch item.kind {
            case .folder:
                menuItem.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                let sub = NSMenu(title: item.name)
                configureFolderMenu(sub, path: item.id, isRoot: false)
                menuItem.submenu = sub
            case .document:
                menuItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
                menuItem.submenu = makeDocumentMenu(for: item)
            }
            menu.addItem(menuItem)
        }

        if isRoot {
            menu.addItem(.separator())

            let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAction(_:)), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)

            let account = NSMenuItem(
                title: client.isAuthenticated ? "Signed in" : "Not signed in",
                action: nil, keyEquivalent: ""
            )
            account.isEnabled = false
            menu.addItem(account)

            let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)
        }
    }

    /// Builds the per-document submenu: save-all plus single-page exports.
    private func makeDocumentMenu(for item: RMItem) -> NSMenu {
        let sub = NSMenu(title: item.name)
        sub.autoenablesItems = false

        let allPages = NSMenuItem(title: "Save as PDF (all pages)…", action: #selector(downloadAllAction(_:)), keyEquivalent: "")
        allPages.target = self
        allPages.representedObject = item.id
        sub.addItem(allPages)
        sub.addItem(.separator())

        addPageItem(to: sub, title: "Export first page…", remotePath: item.id) { _ in 0 }
        addPageItem(to: sub, title: "Export last page…", remotePath: item.id) { count in count - 1 }
        addPageItem(to: sub, title: "Export second-to-last page…", remotePath: item.id) { count in
            count >= 2 ? count - 2 : nil
        }

        let other = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        let otherSub = NSMenu(title: "Other")
        otherSub.autoenablesItems = false
        objc_setAssociatedObject(otherSub, &AssociatedKeys.pageListPath, item.id, .OBJC_ASSOCIATION_RETAIN)
        otherSub.delegate = self
        other.submenu = otherSub
        sub.addItem(other)

        return sub
    }

    /// Add a single-page export item whose target page is resolved once the page count is known.
    private func addPageItem(to menu: NSMenu, title: String, remotePath: String, resolve: @escaping (Int) -> Int?) {
        let mi = NSMenuItem(title: title, action: #selector(exportPageAction(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = PageExportRequest(remotePath: remotePath, resolve: resolve)
        menu.addItem(mi)
    }

    /// Number of pages listed under "Other". We list a fixed count rather than
    /// downloading to count pages; `exportPageAction` validates the choice against
    /// the real page count at export time.
    private static let otherPageListCount = 50

    /// Populate the "Other" submenu with a fixed list of pages.
    private func populatePageListMenu(_ menu: NSMenu, remotePath: String) {
        menu.removeAllItems()
        for n in 1...Self.otherPageListCount {
            addPageItem(to: menu, title: "Page \(n)", remotePath: remotePath) { _ in n - 1 }
        }
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            if let pageListPath = objc_getAssociatedObject(menu, &AssociatedKeys.pageListPath) as? String {
                if !populated.contains(menu) {
                    populated.insert(menu)
                    populatePageListMenu(menu, remotePath: pageListPath)
                }
                return
            }
            guard objc_getAssociatedObject(menu, &AssociatedKeys.folderPath) != nil else { return }
            if !populated.contains(menu) {
                populated.insert(menu)
                populateFolderMenu(menu)
            }
        }
    }

    // MARK: - Actions

    @objc private func refreshAction(_ sender: NSMenuItem) {
        childCache.removeAll()
        preparedCache.removeAll()
        prepareDirs.removeAll()
        populated.removeAll()
        rebuildRootMenu()
    }

    @objc private func signInAction(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        // Open the page where reMarkable issues the one-time code.
        NSWorkspace.shared.open(RMClient.connectURL)

        guard let code = promptForPairingCode() else { return }
        beginBusy()
        currentTask = Task {
            defer { endBusy() }
            do {
                try await client.register(oneTimeCode: code)
                childCache.removeAll()
                preparedCache.removeAll()
                prepareDirs.removeAll()
                populated.removeAll()
                rebuildRootMenu()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func uploadAction(_ sender: NSMenuItem) {
        guard let remoteFolder = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        beginBusy()
        currentTask = Task {
            defer { endBusy() }
            do {
                try await client.upload(localFile: url, remoteFolder: remoteFolder)
                childCache.removeValue(forKey: remoteFolder)
                populated.removeAll()
                rebuildRootMenu()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func downloadAllAction(_ sender: NSMenuItem) {
        guard let remotePath = sender.representedObject as? String else { return }
        currentTask = Task { await downloadAndSave(remotePath: remotePath, pageSelection: nil) }
    }

    @objc private func exportPageAction(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? PageExportRequest else { return }
        currentTask = Task {
            beginBusy()
            defer { endBusy() }
            do {
                let (prepared, dir) = try await cachedPrepare(remotePath: req.remotePath)
                let pageCount = prepared.pageCount
                guard pageCount > 0 else {
                    endBusy()
                    showError(NSError(domain: "PDF", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not read this document."]))
                    return
                }
                guard let idx = req.resolve(pageCount), idx >= 0, idx < pageCount else {
                    endBusy()
                    showError(NSError(domain: "PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "That page doesn't exist in this document."]))
                    return
                }

                // Render/produce only the requested page.
                let source = try await client.makePDF(from: prepared, pageIndices: [idx], destinationDir: dir) { [weak self] msg in
                    self?.setBusyTooltip(msg)
                }
                endBusy()

                let base = (req.remotePath as NSString).lastPathComponent
                guard let dst = savePanel(suggestedName: "\(base) p\(idx + 1).pdf") else { return }
                switch prepared.source {
                case .embeddedPDF:
                    // makePDF returned the full PDF; slice out the one page.
                    try PDFSlicer.extractPages(from: source, indices: [idx], to: dst)
                case .notebook:
                    // makePDF rendered exactly this page; it's already a single-page PDF.
                    try copy(source, to: dst)
                }
            } catch {
                showError(error)
            }
        }
    }

    private func downloadAndSave(remotePath: String, pageSelection: String?) async {
        beginBusy()
        defer { endBusy() }
        do {
            let (prepared, dir) = try await cachedPrepare(remotePath: remotePath)
            let pdf = try await client.makePDF(from: prepared, pageIndices: nil, destinationDir: dir) { [weak self] msg in
                self?.setBusyTooltip(msg)
            }
            endBusy()
            guard let dst = savePanel(suggestedName: ((remotePath as NSString).lastPathComponent) + ".pdf") else { return }
            try copy(pdf, to: dst)
        } catch {
            showError(error)
        }
    }

    /// Download + unzip a document (cheap), reusing a prior download for the same path.
    /// Returns the prepared handle and the temp dir it lives in (for rendering output).
    private func cachedPrepare(remotePath: String) async throws -> (PreparedDocument, URL) {
        if let cached = preparedCache[remotePath], let dir = prepareDirs[remotePath] {
            return (cached, dir)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remarkable-mac-\(UUID().uuidString)", isDirectory: true)
        let prepared = try await client.prepare(remotePath: remotePath, destinationDir: dir) { [weak self] msg in
            self?.setBusyTooltip(msg)
        }
        preparedCache[remotePath] = prepared
        prepareDirs[remotePath] = dir
        return (prepared, dir)
    }

    private func copy(_ source: URL, to dst: URL) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: source, to: dst)
    }

    // MARK: - Menu-bar busy indicator

    private func beginBusy() {
        busyDepth += 1
        guard busyDepth == 1, let button = statusItem.button else { return }
        showCancelItem()
        // Widen the status item so the indeterminate bar isn't clipped.
        let barWidth: CGFloat = 60
        let inset: CGFloat = 4
        statusItem.length = barWidth + inset * 2
        button.image = nil
        let height: CGFloat = 12
        let y = (button.bounds.height - height) / 2
        let bar = NSProgressIndicator(frame: NSRect(x: inset, y: y, width: barWidth, height: height))
        bar.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        bar.usesThreadedAnimation = true
        bar.startAnimation(nil)
        button.addSubview(bar)
        busyIndicator = bar
    }

    private func endBusy() {
        busyDepth = max(0, busyDepth - 1)
        guard busyDepth == 0 else { return }
        hideCancelItem()
        currentTask = nil
        busyIndicator?.stopAnimation(nil)
        busyIndicator?.removeFromSuperview()
        busyIndicator = nil
        if let button = statusItem.button {
            button.image = idleImage
            button.toolTip = nil
        }
        statusItem.length = NSStatusItem.variableLength
    }

    private func setBusyTooltip(_ message: String) {
        statusItem.button?.toolTip = message
    }

    /// Insert a "Cancel" item at the top of the menu so the running operation can be stopped.
    private func showCancelItem() {
        guard let menu = rootMenu, cancelMenuItems.isEmpty else { return }
        let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelAction(_:)), keyEquivalent: "")
        cancel.target = self
        cancel.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        let sep = NSMenuItem.separator()
        menu.insertItem(cancel, at: 0)
        menu.insertItem(sep, at: 1)
        cancelMenuItems = [cancel, sep]
    }

    private func hideCancelItem() {
        guard let menu = rootMenu else { cancelMenuItems.removeAll(); return }
        for item in cancelMenuItems where menu.items.contains(item) {
            menu.removeItem(item)
        }
        cancelMenuItems.removeAll()
    }

    @objc private func cancelAction(_ sender: NSMenuItem) {
        currentTask?.cancel()
        setBusyTooltip("Cancelling…")
    }

    // MARK: - UI helpers

    private func savePanel(suggestedName: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func promptForPairingCode() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign in to reMarkable"
        alert.informativeText = "A browser opened at my.remarkable.com. Sign in there, then enter the 8-character one-time code shown on the page."
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "8-character code"
        alert.accessoryView = field
        DispatchQueue.main.async { alert.window.initialFirstResponder = field }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func showError(_ error: Error) {
        // A user-initiated cancellation isn't an error worth alerting about.
        if error is CancellationError { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }

}

// MARK: - Misc

private enum AssociatedKeys {
    static var folderPath = 0
    static var isRoot = 0
    static var pageListPath = 0
}

/// A request to export a single page of a document. `resolve` maps the (later-known)
/// page count to a 0-based page index, or nil if no such page exists.
private final class PageExportRequest: NSObject {
    let remotePath: String
    let resolve: (Int) -> Int?
    init(remotePath: String, resolve: @escaping (Int) -> Int?) {
        self.remotePath = remotePath
        self.resolve = resolve
    }
}
