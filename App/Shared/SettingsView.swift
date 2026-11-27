import AppKit
import MacosCleanCore
import SwiftUI

/// Settings tabs. The last one shown is remembered (`settingsTab`).
enum SettingsTab: String {
    case general, menuBar, exclusions, about
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                SettingsPane {
                    AppearanceSettingsSection()
                    FullDiskAccessSettingsSection()
                    MascotSettingsSection()
                    HistorySettingsSection()
                }
            }
            Tab("Menu Bar", systemImage: "menubar.rectangle", value: .menuBar) {
                SettingsPane { SystemMonitorSettingsSection() }
            }
            Tab("Excluded Folders", systemImage: "folder.badge.minus", value: .exclusions) {
                SettingsPane { ExclusionSettingsSection() }
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                SettingsPane {
                    AboutHeaderSection()
                    UpdateSettingsSection()
                    LinksSettingsSection()
                }
            }
        }
        .frame(width: 520)
    }
}

private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(minHeight: 380)
    }
}

// MARK: General

private struct AppearanceSettingsSection: View {
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system

    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: appearance) { _, value in value.apply() }
    }
}

private struct FullDiskAccessSettingsSection: View {
    @State private var access = AccessModel()

    var body: some View {
        Section {
            LabeledContent("Full Disk Access") {
                if access.hasFullDiskAccess {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Off", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Button("Open System Settings") { access.openSettings() }
                Button("Check Again") { access.refresh() }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text(access.hasFullDiskAccess
                 ? "macOS Clean can see every cache, log and leftover it knows how to clean."
                 : "Without Full Disk Access, macOS hides many caches, logs and app leftovers, so scans show only part of what can be cleaned. Turn on macOS Clean in System Settings › Privacy & Security › Full Disk Access, then reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }
    }
}

// MARK: Menu Bar

private struct SystemMonitorSettingsSection: View {
    @AppStorage(MonitorSettings.showKey) private var showMonitor = false
    @AppStorage(MonitorSettings.metricKey) private var metric: MenuBarMetric = .disk

    var body: some View {
        Section {
            Toggle("Show system monitor in the menu bar", isOn: $showMonitor)
            Picker("Show in menu bar", selection: $metric) {
                ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!showMonitor)
        } header: {
            Text("System Monitor")
        } footer: {
            Text("Shows free disk space, CPU or memory use in the menu bar. Click it for all three and a shortcut to the app. It updates every few seconds while it's shown and reads nothing but these totals.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: About

private struct AboutHeaderSection: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS Clean").font(.title3.weight(.semibold))
                    Text("Version \(AppInfo.versionAndBuild)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct UpdateSettingsSection: View {
    private let checker = UpdateChecker.shared

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer(minLength: 12)
                Button("Check for Updates") { Task { await checker.check() } }
                    .disabled(checker.state == .checking)
            }
            if case .available(let version, let page) = checker.state {
                HStack {
                    Text("Version \(version) is available.")
                    Spacer()
                    Link("Download…", destination: page)
                        .buttonStyle(.glassProminent)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("macOS Clean asks GitHub for the latest release only when you click Check for Updates. Nothing about you or your Mac is sent, and nothing is installed for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch checker.state {
        case .idle:
            if let last = checker.lastChecked {
                Text("Last checked \(last, format: .relative(presentation: .named))").foregroundStyle(.secondary)
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("macOS Clean is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available:
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LinksSettingsSection: View {
    var body: some View {
        Section {
            LinkRow(title: "GitHub Repository", detail: "Source code, release notes and downloads", symbol: "chevron.left.forwardslash.chevron.right", url: AppLinks.repository)
            LinkRow(title: "Report an Issue", detail: "Opens a new GitHub issue with your app and macOS versions filled in", symbol: "exclamationmark.bubble", url: AppLinks.newIssue)
        } header: {
            Text("Project")
        }
    }
}

private struct LinkRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}
