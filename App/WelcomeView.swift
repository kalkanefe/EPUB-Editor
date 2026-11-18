import SwiftUI

struct WelcomeView: View {
    let open: () -> Void
    let openURLs: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 86, height: 86)
                .accessibilityHidden(true)
            Text("EPUB Edit")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 6)
            Text("Edit a book’s details, cover, and typography.")
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Button("Open EPUB…", action: open)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 22)
            Text("or drop an EPUB here")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text("In Finder, right-click an EPUB and choose Edit. Finder may group it under Services.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            openURLs(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}
