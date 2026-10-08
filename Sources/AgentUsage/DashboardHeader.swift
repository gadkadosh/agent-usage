import SwiftUI

struct DashboardHeader: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onQuit: () -> Void

    // Select the property wrapper, not the newer State macro missing from some CLT installs.
    private typealias HoverState = SwiftUI.State<Bool>
    @HoverState private var isMenuHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent Usage")
                    .font(.title2.weight(.semibold))
                Text("Allowance & local history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            optionsMenu
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button(action: onRefresh) {
                Label(
                    isRefreshing ? "Refreshing…" : "Refresh",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Quit Agent Usage", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 32)
                .background(
                    Color.primary.opacity(isMenuHovered ? 0.12 : 0.05),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isMenuHovered = $0 }
        .accessibilityLabel("More options")
        .help("More options")
    }
}
