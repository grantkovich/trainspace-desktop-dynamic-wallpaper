import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshots") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : "build/snapshots"
    MainActor.assumeIsolated { Snapshots.run(outputDirectory: dir, arguments: arguments) }
} else if let i = arguments.firstIndex(of: "--render-settings") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : "build/settings"
    MainActor.assumeIsolated { SettingsRender.run(outputDirectory: dir) }
} else if let i = arguments.firstIndex(of: "--icon") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : "build/AppIcon.iconset"
    MainActor.assumeIsolated { IconRenderer.run(outputDirectory: dir) }
} else {
    TrainspaceApp.main()
}
