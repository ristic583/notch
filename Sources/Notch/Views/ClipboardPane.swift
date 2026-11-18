import AppKit
import SwiftUI

/// Recent clipboard entries: click to put one back, pin the ones you keep using.
struct ClipboardPane: View {
    let viewModel: NotchViewModel
    @State private var query = ""
    @State private var copiedID: UUID?

    private var items: [ClipboardItem] {
        let all = viewModel.clipboard.items
        guard !query.isEmpty else { return all }
        return all.filter { $0.preview.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                if !viewModel.clipboard.items.isEmpty {
                    Button("Clear") { withAnimation(.snappy) { viewModel.clipboard.clear() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .help("Remove everything except pinned entries")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.1)))

            if items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.settings.clipboardEnabled ? "doc.on.clipboard" : "clipboard")
                        .font(.system(size: 20, weight: .medium))
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipboardRow(item: item,
                                         justCopied: copiedID == item.id,
                                         copy: {
                                             viewModel.clipboard.copy(item)
                                             copiedID = item.id
                                             DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                                 if copiedID == item.id { copiedID = nil }
                                             }
                                         },
                                         pin: { withAnimation(.snappy) { viewModel.clipboard.togglePin(item) } },
                                         remove: { withAnimation(.snappy) { viewModel.clipboard.remove(item) } })
                        }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !viewModel.settings.clipboardEnabled { return "Clipboard history is off (Settings › Clipboard)." }
        return query.isEmpty ? "Copy something and it shows up here." : "Nothing matches “\(query)”."
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let justCopied: Bool
    let copy: () -> Void
    let pin: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(justCopied ? .green : .white.opacity(0.55))
                .frame(width: 16)
            Text(justCopied ? "Copied" : item.preview)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if item.isPinned || isHovering {
                Button(action: pin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.isPinned ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")
            }
            if isHovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(isHovering ? 0.12 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .onTapGesture(perform: copy)
        .help("Click to copy")
    }
}
