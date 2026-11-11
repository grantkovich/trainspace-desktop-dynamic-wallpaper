import SwiftUI
import TrainspaceCore

/// Stations grouped by the systems that stop there (Union Station appears under four).
enum StationDirectory {
    static func grouped(_ rail: RailNetwork?) -> [(TransitSystem, [Station])] {
        guard let rail else { return [] }
        var by: [TransitSystem: [Station]] = [:]
        for (i, s) in rail.stations.enumerated() {
            for system in rail.systems(at: i) { by[system, default: []].append(s) }
        }
        return TransitSystem.allCases.compactMap { system in
            by[system].map { (system, $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
        }
    }

    /// The hubs people reach for first.
    static func favorites(_ region: Region) -> [String] {
        region == .dcBaltimore ? ["Union Station", "Penn Station", "Metro Center", "Gallery Place", "L'Enfant Plaza", "BWI Rail Station"]
            : region.featured
    }
}

/// A menu button listing every station by system.
struct StationMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            let rail = model.rail
            ForEach(StationDirectory.favorites(model.region), id: \.self) { name in
                if let s = rail?.stations.first(where: { $0.name == name }) {
                    Button(name) { model.show(station: s) }
                }
            }
            Divider()
            ForEach(StationDirectory.grouped(rail), id: \.0) { system, stations in
                Menu(system.name) {
                    ForEach(stations, id: \.key) { s in
                        Button(s.name) { model.show(station: s) }
                    }
                }
            }
        } label: {
            Text(model.selectedStation.flatMap { model.rail?.stations[safe: $0]?.name } ?? "Choose a Station")
        }
    }
}

/// Settings › Station View: the station, how close the map is, and the signage style.
struct StationViewSettings: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        SettingsGroup(title: "Show", footer: "Station view puts one station's departure boards on your desktop, lettered like the signs on its platforms, over a close-up map.") {
            Picker("View", selection: $model.settings.viewMode) {
                Text("Network map").tag(ViewMode.network)
                Text("A station's departures").tag(ViewMode.station)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        SettingsGroup(title: "Station") {
            HStack {
                Text(model.rail?.stations.first { $0.key == model.settings.stationKey }?.name ?? "None")
                    .font(.title3.weight(.semibold))
                Spacer()
                StationMenu(model: model).fixedSize()
            }
            TextField("Search stations", text: $query)
                .textFieldStyle(.roundedBorder)
            if !query.isEmpty, let rail = model.rail {
                let matches = rail.stations.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(matches), id: \.key) { s in
                        Button {
                            model.show(station: s)
                            query = ""
                        } label: {
                            HStack {
                                Text(s.name)
                                Spacer()
                                Text(rail.station(key: s.key).map { rail.systems(at: $0).sorted().map(\.name).joined(separator: " · ") } ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("Map radius")
                Slider(value: $model.settings.stationZoomMiles, in: WallpaperSettings.stationZoomRange)
                Text(String(format: "%.1f mi", model.settings.stationZoomMiles))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }

        SettingsGroup(title: "Signage",
                      footer: "Union Station and Penn Station get a split-flap departures board. Metrorail stations get the orange LED platform sign; MARC and VRE stations, the amber one; Light RailLink and Metro SubwayLink, the red one. Times come from the timetable, corrected by live data where the feeds have it.") {
            Toggle("Agency typefaces on the map and signs", isOn: $model.settings.agencyTypography)
            SettingsRow(title: "Boards sit in the") {
                Picker("Corner", selection: $model.settings.infoCorner) {
                    Text("Top left").tag(Corner.topLeft)
                    Text("Top right").tag(Corner.topRight)
                    Text("Bottom left").tag(Corner.bottomLeft)
                    Text("Bottom right").tag(Corner.bottomRight)
                }
            }
        }
    }
}

/// Which metro area the wallpaper shows.
struct RegionPicker: View {
    let model: AppModel

    var body: some View {
        Picker("Region", selection: Binding(
            get: { model.settings.region },
            set: { id in model.choose(region: Region.with(id: id)) })) {
            ForEach(Region.all) { r in Text(r.name).tag(r.id) }
        }
    }
}
