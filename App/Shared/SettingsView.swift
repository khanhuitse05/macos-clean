import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            MascotSettingsSection()
            ExclusionSettingsSection()
            HistorySettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 360)
    }
}
