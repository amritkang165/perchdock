import SwiftUI
import AppKit

/// MacDock's settings: Appearance, Behavior and General tabs. Every control
/// writes straight to `SettingsStore`, so the dock updates live.
struct SettingsView: View {
    @Bindable var objSettings: SettingsStore
    let objThumbnailService: ThumbnailService

    var body: some View {
        TabView {
            AppearanceTab(objSettings: objSettings)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorTab(objSettings: objSettings)
                .tabItem { Label("Behavior", systemImage: "cursorarrow.motionlines") }
            GeneralTab(objSettings: objSettings, objThumbnailService: objThumbnailService)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Icon size, magnification and screen position.
private struct AppearanceTab: View {
    @Bindable var objSettings: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledSlider(strTitle: "Icon size", fltValue: $objSettings.fltIconSize, objRange: 32...96, fltStep: 1) {
                    "\(Int($0)) pt"
                }
            }

            Section {
                Toggle("Magnification", isOn: $objSettings.blnMagnificationOn)
                LabeledSlider(strTitle: "Amount", fltValue: $objSettings.fltMagnification, objRange: 1.1...2.0, fltStep: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                .disabled(!objSettings.blnMagnificationOn)
            }

            Section {
                Picker("Position on screen", selection: $objSettings.enmPosition) {
                    ForEach(DockPosition.allCases) { enmPosition in
                        Text(enmPosition.strTitle).tag(enmPosition)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Show dock on", selection: $objSettings.enmDisplayMode) {
                    ForEach(DockDisplayMode.allCases) { enmMode in
                        Text(enmMode.strTitle).tag(enmMode)
                    }
                }
            } footer: {
                if objSettings.enmDisplayMode == .followCursor {
                    Text("Push the cursor against the dock's edge on another display to move the dock there.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Tint", selection: $objSettings.enmTint) {
                    ForEach(DockTint.allCases) { enmTint in
                        Text(enmTint.strTitle).tag(enmTint)
                    }
                }
                if objSettings.enmTint == .custom {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(strHex: objSettings.strTintHex) },
                        set: { objSettings.strTintHex = $0.strHex }
                    ), supportsOpacity: false)
                }
                LabeledSlider(strTitle: "Strength", fltValue: $objSettings.fltTintStrength, objRange: 0.05...0.9, fltStep: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                .disabled(objSettings.enmTint == .none)
                Toggle("Compact", isOn: $objSettings.blnCompact)
                Picker("Running indicator", selection: $objSettings.enmIndicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { enmStyle in
                        Text(enmStyle.strTitle).tag(enmStyle)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Style")
            }

            Section {
                Toggle("Show app names on hover", isOn: $objSettings.blnShowLabels)
                Toggle("Show minimized windows in the dock", isOn: $objSettings.blnShowMinimized)
                Toggle("Show Trash", isOn: $objSettings.blnShowTrash)
            } footer: {
                Text("Right-click the dock to add dividers or folders. Hold an app over another app to make a group, or drop it on a group to add it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Now Playing", isOn: $objSettings.blnShowNowPlaying)
                Picker("Now Playing size", selection: $objSettings.enmNowPlayingSize) {
                    ForEach(NowPlayingSize.allCases) { enmSize in
                        Text(enmSize.strTitle).tag(enmSize)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!objSettings.blnShowNowPlaying)
                Toggle("Battery", isOn: $objSettings.blnShowBattery)
            } header: {
                Text("Widgets")
            } footer: {
                Text("Now Playing appears while music or a video is playing or paused. Small is a single tile: click to play or pause, right-click to skip. Large adds previous/next, a seek bar, mute and volume (wide at the bottom, tall on a side dock). Battery shows the charge; click it for Battery settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Auto-hide timing and preview delay.
private struct BehaviorTab: View {
    @Bindable var objSettings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Automatically hide and show the dock", isOn: $objSettings.blnAutoHide)
                LabeledSlider(strTitle: "Show delay", fltValue: $objSettings.fltShowDelay, objRange: 0...1, fltStep: 0.05) {
                    String(format: "%.2fs", $0)
                }
                .disabled(!objSettings.blnAutoHide)
                LabeledSlider(strTitle: "Hide delay", fltValue: $objSettings.fltHideDelay, objRange: 0...2, fltStep: 0.05) {
                    String(format: "%.2fs", $0)
                }
                .disabled(!objSettings.blnAutoHide)
            }

            Section {
                LabeledSlider(strTitle: "Window preview delay", fltValue: $objSettings.fltPreviewDelay, objRange: 0...1, fltStep: 0.02) {
                    String(format: "%.2fs", $0)
                }
                Toggle("Live previews", isOn: $objSettings.blnLivePreviews)
                Toggle("Reduce to 30 fps on battery", isOn: $objSettings.blnReducePreviewsOnBattery)
                    .disabled(!objSettings.blnLivePreviews)
                Toggle("Only show windows on this desktop", isOn: $objSettings.blnCurrentDesktopOnly)
                Toggle("Peek at a window when hovering its preview", isOn: $objSettings.blnPeek)
            } footer: {
                Text("The delay is how long to hover an icon before its windows appear. Live previews play at 60 fps while open and stop when closed. Windows on other desktops show their last snapshot, or are left out when \"Only show windows on this desktop\" is on (minimized windows still show). Battery saving also applies in Low Power Mode.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Native Dock, login item and permissions.
private struct GeneralTab: View {
    @Bindable var objSettings: SettingsStore
    let objThumbnailService: ThumbnailService

    @State private var blnAccessibility = AccessibilityPermission.blnIsTrusted
    @State private var blnScreenRecording = false

    var body: some View {
        Form {
            Section {
                Toggle("Hide the native macOS Dock", isOn: $objSettings.blnHideNativeDock)
                Toggle("Launch MacDock at login", isOn: Binding(
                    get: { objSettings.blnLaunchAtLogin },
                    set: { objSettings.setLaunchAtLogin($0) }
                ))
            } footer: {
                Text("The native Dock comes back automatically when MacDock quits.")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    strTitle: "Accessibility",
                    strDetail: "List and raise individual windows",
                    blnGranted: blnAccessibility,
                    fnOpen: AccessibilityPermission.openSystemSettings
                )
                PermissionRow(
                    strTitle: "Screen Recording",
                    strDetail: "Live window previews",
                    blnGranted: blnScreenRecording,
                    fnOpen: {
                        if let objUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(objUrl)
                        }
                    }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPermissions)
        // Pick up grants made in System Settings while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    /// Re-reads both permission states.
    private func refreshPermissions() {
        blnAccessibility = AccessibilityPermission.blnIsTrusted
        blnScreenRecording = objThumbnailService.blnHasPermission
    }
}

/// A permission's status with a shortcut to its System Settings pane.
private struct PermissionRow: View {
    let strTitle: String
    let strDetail: String
    let blnGranted: Bool
    let fnOpen: () -> Void

    var body: some View {
        HStack {
            Image(systemName: blnGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(blnGranted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(strTitle)
                Text(strDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !blnGranted {
                Button("Open Settings…", action: fnOpen)
            }
        }
    }
}

/// Slider with a title and a formatted live value.
private struct LabeledSlider: View {
    let strTitle: String
    @Binding var fltValue: Double
    let objRange: ClosedRange<Double>
    let fltStep: Double
    let fnFormat: (Double) -> String

    /// Creates the slider.
    /// - Parameters:
    ///   - strTitle: Label.
    ///   - fltValue: Bound value.
    ///   - objRange: Allowed range.
    ///   - fltStep: Increment.
    ///   - fnFormat: Formats the current value for display.
    init(strTitle: String, fltValue: Binding<Double>, objRange: ClosedRange<Double>, fltStep: Double, fnFormat: @escaping (Double) -> String) {
        self.strTitle = strTitle
        self._fltValue = fltValue
        self.objRange = objRange
        self.fltStep = fltStep
        self.fnFormat = fnFormat
    }

    var body: some View {
        LabeledContent(strTitle) {
            HStack(spacing: 10) {
                Slider(value: $fltValue, in: objRange, step: fltStep)
                Text(fnFormat(fltValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
