import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import EPUBCore

struct EditorView: View {
    @ObservedObject var document: EPUBDocument
    @State private var formatting = false

    var body: some View {
        HStack(spacing: 0) {
            CoverView(document: document)
                .frame(width: 192)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker("Editor section", selection: $formatting) {
                        Text("Details").tag(false)
                        Text("Formatting").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button(action: document.fixForKindle) {
                        if document.isFixingKindle {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Text("Fix for Kindle")
                        }
                    }
                    .disabled(document.isFixingKindle)
                    .help("Check the current edits and save a repaired EPUB beside this book.")
                }
                .padding(.bottom, 24)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let notice = document.kindleNotice {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(notice.title).font(.headline).textSelection(.enabled)
                                Text(notice.detail).font(.callout).foregroundStyle(.secondary)
                                if let file = notice.file {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([file])
                                    }
                                    .padding(.top, 3)
                                }
                            }
                            Divider()
                        }
                        if formatting {
                            formattingControls
                        } else {
                            metadataFields
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(-4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var metadataFields: some View {
        Text("Book details").font(.title2.bold()).accessibilityAddTraits(.isHeader)
        field("Title", text: $document.metadata.title)
        field("Author", text: $document.metadata.author)
        HStack(alignment: .top, spacing: 16) {
            field("Publisher", text: $document.metadata.publisher)
            field("Language", text: $document.metadata.language, prompt: "e.g. en")
                .frame(width: 108)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.headline)
            TextEditor(text: $document.metadata.description)
                .font(.body)
                .padding(5)
                .scrollContentBackground(.hidden)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .frame(minHeight: 105, idealHeight: 125)
                .accessibilityLabel("Description")
        }
    }

    private func field(_ name: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.headline)
            TextField(name, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityLabel(name)
        }
    }

    @ViewBuilder private var formattingControls: some View {
        Text("Reading format").font(.title2.bold()).accessibilityAddTraits(.isHeader)
        if document.book?.allowsFormatting == true {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text("Font")
                    Picker("Font", selection: $document.metadata.font) {
                        Text("Book default").tag(BookFont.original)
                        Text("Serif").tag(BookFont.serif)
                        Text("Sans serif").tag(BookFont.sansSerif)
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Line spacing")
                    Picker("Line spacing", selection: $document.metadata.lineSpacing) {
                        Text("Book default").tag(BookLineSpacing.original)
                        Text("Comfortable").tag(BookLineSpacing.comfortable)
                        Text("Spacious").tag(BookLineSpacing.spacious)
                    }
                    .labelsHidden()
                }
            }
            .frame(maxWidth: 350, alignment: .leading)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Type sample").font(.headline)
                Text("Evening light fell across the open book. Outside the window, the last birds drifted home and the garden settled into silence.")
                    .font(.system(size: 18, design: document.metadata.font == .sansSerif ? .default : .serif))
                    .lineSpacing(document.metadata.lineSpacing == .spacious ? 11 : document.metadata.lineSpacing == .comfortable ? 6 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1) }
            }
            Text("Reading apps can override the book’s typography.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Font and line spacing are available for reflowable books with editable text chapters.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CoverView: View {
    @ObservedObject var document: EPUBDocument
    @State private var thumbnail: NSImage?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
                        .accessibilityLabel("Book cover")
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.quaternary.opacity(0.65))
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: "book.closed").font(.system(size: 30, weight: .light))
                                Text(document.coverData == nil ? "No cover" : "Cover preview unavailable")
                                    .font(.callout).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.secondary)
                            .padding(10)
                        }
                        .accessibilityElement(children: .combine)
                }
            }
            .frame(width: 144, height: 202)
            Button(document.coverData == nil ? "Add Cover…" : "Change Cover…", action: chooseCover)
            if let version = document.book?.version {
                Text("EPUB " + version)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 30)
        .task(id: document.coverData) {
            thumbnail = document.coverData.flatMap(Self.thumbnail(for:))
        }
        .alert("Couldn’t use this cover", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: { Text(problem ?? "") }
    }

    private static func thumbnail(for data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = "Use Cover"
        guard let window = document.windowControllers.first?.window else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024 else {
                    problem = "Choose a JPEG or PNG smaller than 32 MB."
                    return
                }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source),
                      [UTType.jpeg.identifier, UTType.png.identifier].contains(type as String),
                      Self.thumbnail(for: data) != nil else {
                    problem = "Choose a readable JPEG or PNG image."
                    return
                }
                document.replacementCover = data
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
