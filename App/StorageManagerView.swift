import MacosCleanCore
import SwiftUI

/// Placeholder Storage Manager: lists the categories from `MacosCleanCore` so the app ↔ package
/// wiring is proven end to end. Scanning, sizes and selection come next.
struct StorageManagerView: View {
    var body: some View {
        List(CleanupCategory.all) { category in
            CategoryRow(
                name: category.name,
                details: category.details,
                safetyLabel: category.safety.label,
                isCaution: category.safety == .caution
            )
        }
    }
}

private struct CategoryRow: View {
    let name: LocalizedStringResource
    let details: LocalizedStringResource
    let safetyLabel: LocalizedStringResource
    let isCaution: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.headline)
                Text(safetyLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isCaution ? Color.yellow.opacity(0.25) : Color.green.opacity(0.2), in: .capsule)
            }
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    StorageManagerView()
}
