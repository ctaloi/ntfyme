import SwiftUI
import UniformTypeIdentifiers
import NtfyKit

/// The subscription import/export picker: every subscription on one list,
/// a checkbox on each, because "export my subs" and "import these three"
/// are the same surface wearing different titles.
///
/// Confirm hands back the *selected* rows only; everything about files —
/// save panels, reading, the actual import — stays with the caller, so the
/// sheet is pure selection and can render identically for either direction.
struct SubscriptionsTransferSheet: View {
    let title: String
    let message: String
    let confirmLabel: String
    /// Destructive-styled confirm (used for import, where acting on a file
    /// is the bolder act than writing one).
    var confirmIsProminent: Bool = true
    let rows: [SubscriptionTransfer]
    let onDismiss: () -> Void
    /// Receives the ids of the checked rows, in list order.
    let onConfirm: ([SubscriptionTransfer]) -> Void

    @State private var selected: Set<String>
    @State private var isWorking = false

    init(title: String, message: String, confirmLabel: String,
         confirmIsProminent: Bool = true, rows: [SubscriptionTransfer],
         onDismiss: @escaping () -> Void,
         onConfirm: @escaping ([SubscriptionTransfer]) -> Void) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.confirmIsProminent = confirmIsProminent
        self.rows = rows
        self.onDismiss = onDismiss
        self.onConfirm = onConfirm
        // Everything starts checked: the overwhelmingly common case is
        // "all of them", and unchecking two rows is faster than checking
        // twenty.
        _selected = State(initialValue: Set(rows.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            List(rows) { row in
                Toggle(isOn: Binding(
                    get: { selected.contains(row.id) },
                    set: { isOn in
                        if isOn { selected.insert(row.id) } else { selected.remove(row.id) }
                    })) {
                    HStack(spacing: 6) {
                        Text(row.topic)
                            .font(.system(size: 13, weight: .medium).monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if row.muted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel(Text("Muted"))
                        }
                        Spacer(minLength: 8)
                        Text(host(for: row))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text("\(row.topic) on \(host(for: row))"))
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button("Select All") { selected = Set(rows.map(\.id)) }
                    .disabled(selected.count == rows.count)
                Button("None") { selected = [] }
                    .disabled(selected.isEmpty)
                Spacer()
                Text("\(selected.count) of \(rows.count) selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    isWorking = true
                    let picks = rows.filter { selected.contains($0.id) }
                    onConfirm(picks)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || isWorking)
                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(12)
        }
        .frame(width: 440, height: 460)
        .settingsBackground()
    }

    private func host(for row: SubscriptionTransfer) -> String {
        SubscriptionsTransferCodec.normalizedServerURL(row.server)?.host ?? row.server
    }
}
