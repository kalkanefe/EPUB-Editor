import AppKit
import EPUBCore
import SwiftUI

@main
enum EditorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        NSApp.servicesProvider = self
        _ = NSDocumentController.shared
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcome()
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible && NSDocumentController.shared.documents.isEmpty { showWelcome() }
        return true
    }

    private func showWelcome() {
        if welcome == nil {
            let view = WelcomeView(open: { NSDocumentController.shared.openDocument(nil) },
                                   openURLs: { [weak self] in self?.openURLs($0) })
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "EPUB Edit"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.contentMinSize = NSSize(width: 500, height: 360)
            window.setContentSize(NSSize(width: 520, height: 380))
            window.isReleasedWhenClosed = false
            window.center()
            welcome = window
        }
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hideWelcome() { welcome?.orderOut(nil) }

    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls)
    }

    @objc func editEPUB(_ pasteboard: NSPasteboard, userData: String?,
                        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = Self.epubURLs(from: pasteboard) else {
            errorPointer.pointee = "Select one or more EPUB files in Finder."
            return
        }
        openURLs(urls)
    }

    static func epubURLs(from pasteboard: NSPasteboard) -> [URL]? {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if urls.isEmpty,
           let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty, urls.allSatisfy({
            $0.isFileURL && !$0.hasDirectoryPath && $0.pathExtension.lowercased() == "epub"
        }) else { return nil }
        return urls
    }

    private func openURLs(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL, url.pathExtension.lowercased() == "epub" else {
                NSApp.presentError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                    userInfo: [NSLocalizedDescriptionKey: "Choose an .epub file to edit."]))
                continue
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
                else { NSApp.activate() }
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let submenu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: String, _ key: String = "",
                  modifiers: NSEvent.ModifierFlags = .command) {
            menu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
                .keyEquivalentModifierMask = modifiers
        }

        let app = menu("EPUB Edit")
        item(app, "About EPUB Edit", "orderFrontStandardAboutPanel:")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide EPUB Edit", "hide:", "h")
        item(app, "Hide Others", "hideOtherApplications:", "h", modifiers: [.command, .option])
        item(app, "Show All", "unhideAllApplications:")
        app.addItem(.separator())
        item(app, "Quit EPUB Edit", "terminate:", "q")
        let file = menu("File")
        item(file, "Open…", "openDocument:", "o")
        file.addItem(.separator())
        item(file, "Close", "performClose:", "w")
        item(file, "Save", "saveDocument:", "s")
        item(file, "Save As…", "saveDocumentAs:", "s", modifiers: [.command, .shift])
        let edit = menu("Edit")
        item(edit, "Undo", "undo:", "z")
        item(edit, "Redo", "redo:", "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", "cut:", "x")
        item(edit, "Copy", "copy:", "c")
        item(edit, "Paste", "paste:", "v")
        item(edit, "Select All", "selectAll:", "a")
        let window = menu("Window")
        item(window, "Minimize", "performMiniaturize:", "m")
        item(window, "Zoom", "performZoom:")
        NSApp.windowsMenu = window
        return main
    }
}

@objc(EPUBDocument)
final class EPUBDocument: NSDocument, ObservableObject, NSToolbarDelegate {
    @Published private(set) var book: EPUBBook?
    @Published var metadata = BookMetadata() {
        didSet {
            guard book != nil, metadata != oldValue else { return }
            undoManager?.registerUndo(withTarget: self) { $0.metadata = oldValue }
        }
    }
    @Published var replacementCover: Data? {
        didSet {
            guard book != nil, replacementCover != oldValue else { return }
            undoManager?.registerUndo(withTarget: self) { $0.replacementCover = oldValue }
        }
    }
    var coverData: Data? { replacementCover ?? book?.coverData }
    var hasChanges: Bool { isDocumentEdited }

    @Published private(set) var isFixingKindle = false
    @Published private(set) var kindleNotice: KindleExportNotice?

    func fixForKindle() {
        guard !isFixingKindle, let book, let fileURL else { return }
        guard book.allowsFormatting else {
            kindleNotice = KindleExportNotice(title: "This book keeps its original layout.",
                                              detail: "Kindle repair is available for reflowable text chapters.")
            return
        }
        let edits = metadata
        let cover = replacementCover
        isFixingKindle = true
        kindleNotice = nil
        Task {
            defer { isFixingKindle = false }
            do {
                kindleNotice = try await Task.detached(priority: .userInitiated) {
                    try KindleExportNotice.make(book: book, edits: edits, cover: cover, source: fileURL)
                }.value
            } catch {
                kindleNotice = KindleExportNotice(title: "Couldn’t create the Kindle copy.",
                                                  detail: error.localizedDescription)
            }
        }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Choose a packaged .epub file."])
        }
        guard let size = resource.fileSize, size <= 512 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "This EPUB exceeds the 512 MB editing limit."])
        }
        try read(from: Data(contentsOf: url, options: .mappedIfSafe), ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // NSDocument's default synchronous reading keeps document state on the main thread.
        try MainActor.assumeIsolated {
            let loaded = try EPUBBook(data: data)
            book = nil
            metadata = loaded.metadata
            replacementCover = nil
            book = loaded
            undoManager?.removeAllActions()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let book else { throw CocoaError(.fileReadCorruptFile) }
        return try book.writing(metadata: metadata, replacementCover: replacementCover)
    }

    override func makeWindowControllers() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(document: self)))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 610))
        window.contentMinSize = NSSize(width: 640, height: 505)
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "EPUBEditor")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.center()
        addWindowController(NSWindowController(window: window))
        (NSApp.delegate as? AppDelegate)?.hideWelcome()
    }

    private static let saveItem = NSToolbarItem.Identifier("saveEPUB")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.saveItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.saveItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let command = NSMenuItem(title: "Save", action: #selector(save(_:)), keyEquivalent: "")
        command.target = self
        item.menuFormRepresentation = command
        item.title = command.title
        // AppKit draws the item label below the button in Icon and Text mode.
        item.label = ""
        item.paletteLabel = command.title
        item.toolTip = "Save changes to this EPUB (⌘S)"
        item.target = self
        item.action = command.action
        item.style = .prominent
        return item
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(save(_:)) { return hasChanges }
        return super.validateUserInterfaceItem(item)
    }
}
