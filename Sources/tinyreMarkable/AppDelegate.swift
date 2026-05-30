import AppKit
import PDFKit
import UniformTypeIdentifiers

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

    /// Set to true by a task right before it completes successfully; consumed by
    /// `endBusy()`, which then flashes a checkmark instead of restoring the logo
    /// immediately. Avoids threading a "result" through every defer.
    private var pendingSuccess: Bool = false
    /// In-flight "restore the logo after the flash" task, so a new operation
    /// starting mid-flash cancels the restore cleanly.
    private var successFlashTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? client.bootstrapAuthIfNeeded()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = Self.makeStatusItemImage()
            button.image = image
            self.idleImage = image

            let drag = DragReceivingView(frame: button.bounds)
            drag.autoresizingMask = [.width, .height]
            drag.onDrop = { [weak self] url in
                self?.performUpload(localURL: url, remoteFolder: "/")
            }
            button.addSubview(drag)
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

        // Add the bottom-anchored items NOW (separator + Refresh/Account/Quit for root).
        // Doing this up-front means the menu's full vertical structure is known at first
        // display; the async fetch only replaces the Loading row with children — a pure
        // mid-menu swap. If we waited to append these after the async, NSMenu wouldn't
        // fully reflow its window height while the menu is on screen, leaving a stale
        // blank row at the bottom until the user closed and reopened.
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

        // Fetch (use cache if available)
        if let cached = childCache[path] {
            replaceLoadingWithChildren(cached, in: menu, parentPath: path, loadingPlaceholder: loading)
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let items = try await self.client.list(path: path)
                    self.childCache[path] = items
                    if menu.items.contains(loading) {
                        self.replaceLoadingWithChildren(items, in: menu, parentPath: path, loadingPlaceholder: loading)
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

    /// Insert child items at the Loading placeholder's position, then remove the placeholder.
    /// The trailing Refresh/Account/Quit section is already in place (added by `populateFolderMenu`),
    /// so this is a pure middle-of-menu replacement.
    private func replaceLoadingWithChildren(_ items: [RMItem], in menu: NSMenu, parentPath: String, loadingPlaceholder: NSMenuItem) {
        let insertIndex = menu.index(of: loadingPlaceholder)
        guard insertIndex >= 0 else { return }

        var offset = insertIndex
        if items.isEmpty {
            let empty = NSMenuItem(title: "(empty)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.insertItem(empty, at: offset)
            offset += 1
        } else {
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
                menu.insertItem(menuItem, at: offset)
                offset += 1
            }
        }

        menu.removeItem(loadingPlaceholder)
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
                pendingSuccess = true
            } catch {
                showError(error)
            }
        }
    }

    @objc private func uploadAction(_ sender: NSMenuItem) {
        guard let remoteFolder = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        performUpload(localURL: url, remoteFolder: remoteFolder)
    }

    /// Run the upload pipeline for a local file (PDF or image): convert images to
    /// PDF if needed, push to `remoteFolder`, then invalidate caches and rebuild.
    private func performUpload(localURL: URL, remoteFolder: String) {
        beginBusy()
        currentTask = Task {
            defer { endBusy() }
            do {
                let uploadURL: URL
                if Self.isImage(localURL) {
                    setBusyTooltip("Converting image to PDF…")
                    uploadURL = try Self.makePDF(fromImage: localURL)
                } else {
                    uploadURL = localURL
                }
                try await client.upload(localFile: uploadURL, remoteFolder: remoteFolder)
                childCache.removeValue(forKey: remoteFolder)
                populated.removeAll()
                rebuildRootMenu()
                pendingSuccess = true
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
                // Flash success before the save panel: the work is done, and we
                // don't want any menu-bar animation while the panel is up.
                pendingSuccess = true
                endBusy()

                let base = (req.remotePath as NSString).lastPathComponent
                guard let dst = savePanel(suggestedName: "\(base) p\(idx + 1).pdf") else { return }
                switch prepared.source {
                case .embeddedPDF:
                    // makePDF returned the full PDF; slice out the one page.
                    try PDFSlicer.extractPages(from: source, indices: [idx], to: dst)
                case .annotatedPDF, .notebook:
                    // makePDF rendered/composited exactly this page; it's already a single-page PDF.
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
            // Flash success before the save panel: the download is done, and we
            // don't want any menu-bar animation while the panel is up.
            pendingSuccess = true
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
        // A new operation supersedes any lingering success flash.
        successFlashTask?.cancel()
        successFlashTask = nil
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
        // Idempotent: extra calls (e.g. a `defer { endBusy() }` after an
        // explicit pre-save-panel `endBusy()`) become no-ops so they don't
        // overwrite the success flash with the idle logo.
        guard busyDepth > 0 else { return }
        busyDepth -= 1
        guard busyDepth == 0 else { return }
        hideCancelItem()
        currentTask = nil
        busyIndicator?.stopAnimation(nil)
        busyIndicator?.removeFromSuperview()
        busyIndicator = nil
        if let button = statusItem.button {
            button.toolTip = nil
        }
        statusItem.length = NSStatusItem.variableLength

        let success = pendingSuccess
        pendingSuccess = false
        if success {
            flashSuccess()
        } else {
            statusItem.button?.image = idleImage
        }
    }

    /// Briefly swap the status item image for a checkmark, then transition back
    /// to the reMarkable logo via a scale-down → swap → scale-up animation.
    /// Cancelled by `beginBusy` if a new operation supersedes it.
    private func flashSuccess() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let check = NSImage(systemSymbolName: "checkmark",
                            accessibilityDescription: "Success")?
            .withSymbolConfiguration(config)
        check?.isTemplate = true
        button.image = check

        // Entry: scale up from a small size around the layer's center.
        // We don't change the layer's anchorPoint (AppKit fights us on it);
        // instead the scale is baked into a center-pivoting transform matrix.
        let entryScale = CABasicAnimation(keyPath: "transform")
        entryScale.fromValue = NSValue(caTransform3D: Self.centeredScale(0.4, in: layer))
        entryScale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        entryScale.duration = 0.18
        entryScale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(entryScale, forKey: "successEntryScale")

        let entryFade = CABasicAnimation(keyPath: "opacity")
        entryFade.fromValue = 0.0
        entryFade.toValue = 1.0
        entryFade.duration = 0.18
        layer.add(entryFade, forKey: "successEntryFade")

        successFlashTask = Task { [weak self] in
            // Hold the checkmark at full size.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self,
                  let button = self.statusItem.button,
                  let layer = button.layer else { return }

            let shrunk = Self.centeredScale(0.4, in: layer)

            // Shrink the checkmark (hold the shrunk state so it doesn't snap back
            // before we swap the image).
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: shrunk)
            shrink.duration = 0.13
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "successShrink")

            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled,
                  let button = self.statusItem.button,
                  let layer = button.layer else { return }

            // Swap to logo and scale back up.
            button.image = self.idleImage
            layer.removeAnimation(forKey: "successShrink")
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: shrunk)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.duration = 0.18
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(grow, forKey: "successGrow")

            self.successFlashTask = nil
        }
    }

    /// Build a uniform-scale transform that pivots around the layer's visual
    /// center, regardless of the layer's anchorPoint. Used because
    /// `NSStatusBarButton`'s AppKit-managed layer resets anchorPoint changes
    /// during layout, so a plain `transform.scale` animation pins to the
    /// bottom-left corner instead of the middle.
    private static func centeredScale(_ s: CGFloat, in layer: CALayer) -> CATransform3D {
        let cx = layer.bounds.width / 2
        let cy = layer.bounds.height / 2
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
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

    /// True if `url` looks like an image we can wrap in a PDF.
    private static func isImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return false
    }

    /// Wrap an image file in a single-page PDF (page size = image size) and return
    /// the new file's URL in a temporary directory. Filename is `<image-basename>.pdf`.
    private static func makePDF(fromImage url: URL) throws -> URL {
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
            throw NSError(domain: "tinyreMarkable", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not read the selected image."
            ])
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remarkable-mac-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        guard doc.write(to: dst) else {
            throw NSError(domain: "tinyreMarkable", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not write the converted PDF."
            ])
        }
        return dst
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

/// Transparent overlay sitting on top of the status item button that accepts
/// dragged PDF/image files. `hitTest` returns nil so clicks fall through to the
/// button (which opens the menu); the window resolves drag destinations by the
/// registered view's frame independently of hit testing.
@MainActor
final class DragReceivingView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    nonisolated override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            acceptableURL(from: sender) != nil ? .copy : []
        }
    }

    nonisolated override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            acceptableURL(from: sender) != nil ? .copy : []
        }
    }

    nonisolated override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let url = acceptableURL(from: sender) else { return false }
            onDrop?(url)
            return true
        }
    }

    private func acceptableURL(from sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.first(where: { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
                return false
            }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        })
    }
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
