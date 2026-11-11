import SwiftUI
import TrainspaceCore

/// The menu-bar dropdown: status at a glance plus the settings people reach for most.
struct MenuPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.mapCenter == nil && !model.isResolvingLocation {
                Button {
                    WindowRouter.shared.open(model.settings.hasCompletedOnboarding ? .settings : .welcome)
                } label: {
                    Label("Choose Location…", systemImage: "location").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            Divider()
            row("View") {
                HStack {
                    Picker("View", selection: $model.settings.viewMode) {
                        Text("Network").tag(ViewMode.network)
                        Text("Station").tag(ViewMode.station)
                    }
                    if model.settings.viewMode == .station {
                        StationMenu(model: model).pickerStyle(.menu).fixedSize()
                    }
                }
            }
            row("Region") {
                RegionPicker(model: model)
            }
            row("Go to") {
                HStack(spacing: 6) {
                    ForEach(model.region.presets) { preset in
                        Button(preset.name) { model.choose(preset) }
                            .controlSize(.small)
                    }
                }
            }
            row("Appearance") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                    Text("Dynamic").tag(AppearanceMode.dynamic)
                }
            }
            row("Map") {
                Picker("Map", selection: $model.settings.mapStyle) {
                    Text("Schematic").tag(MapStyle.schematic)
                    Text("Apple").tag(MapStyle.appleMap)
                    Text("Field").tag(MapStyle.pureField)
                }
            }
            row("Labels") {
                Picker("Labels", selection: $model.settings.labelMode) {
                    Text("Off").tag(LabelMode.off)
                    Text("Train").tag(LabelMode.train)
                    Text("+ Destination").tag(LabelMode.trainDestination)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zoom").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.settings.viewMode == .station ? String(format: "%.1f mi radius", model.settings.stationZoomMiles)
                         : "\(Int(model.settings.zoomMiles)) mi radius").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if model.settings.viewMode == .station {
                    Slider(value: $model.settings.stationZoomMiles, in: WallpaperSettings.stationZoomRange)
                } else {
                    Slider(value: $model.settings.zoomMiles, in: WallpaperSettings.zoomRange)
                }
            }
            if model.wallpaperNeedsManualRestore {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trainspace couldn't put your own wallpaper back by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore My Wallpaper…") { model.restoreWallpaperManually?() }
                }
            }
            Divider()
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.paused.toggle() }
                Spacer()
                Button("About") { AboutPanel.show() }
                Button("Settings…") { WindowRouter.shared.open(.settings) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.regular)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.placeName.uppercased())
                .font(.system(size: 15, weight: .semibold).width(.expanded))
                .tracking(1.5)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private var statusText: String {
        if model.mapCenter == nil { return model.locationMessage == nil ? "Waiting for a location" : "Location unavailable" }
        if model.paused { return "Paused" }
        switch model.powerMode.kind {
        case .suspended: return "Sleeping"
        case .occluded: return "Hidden behind windows · idle"
        default: break
        }
        if model.isStale { return "No signal · showing the timetable" }
        let live = TransitSystem.allCases.filter { model.feeds[$0]?.mode == .live }.count
        let enabled = model.settings.systems.count
        let battery = model.powerMode.kind == .battery ? " · battery saver" : ""
        return "\(model.trainsInView) trains · \(live) of \(enabled) systems live\(battery)"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
