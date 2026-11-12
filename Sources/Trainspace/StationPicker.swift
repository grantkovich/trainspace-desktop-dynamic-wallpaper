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
            Button {
                model.followNearestStation()
            } label: {
                Label("Nearest to Me", systemImage: "location.fill")
            }
            Divider()
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
            let name = model.selectedStation.flatMap { model.rail?.stations[safe: $0]?.name }
            if model.followsNearestStation {
                Text(name.map { "Nearest: \($0)" } ?? "Nearest to Me")
            } else {
                Text(name ?? "Choose a Station")
            }
        }
    }
}

/// Settings › Station View: the station (or the one nearest you), how close the map is, and
/// the boards.
struct StationViewSettings: View {
    @Bindable var model: AppModel
    @State private var query = ""

    /// The three choices on one control: the network map, a station you pick, or the station
    /// nearest you.
    private enum Show: Hashable { case network, station, nearest }

    private var show: Binding<Show> {
        Binding {
            model.settings.viewMode == .network ? .network : model.settings.stationChoice == .nearest ? .nearest : .station
        } set: { choice in
            switch choice {
            case .network: model.settings.viewMode = .network
            case .station: model.settings.stationChoice = .fixed; model.settings.viewMode = .station
            case .nearest: model.followNearestStation()
            }
        }
    }

    var body: some View {
        SettingsGroup(title: "Show", footer: "Station view puts one station's departure boards on your desktop, over a close-up map. “Nearest me” follows your location and switches to the closest station as you move.") {
            Picker("View", selection: show) {
                Text("Network map").tag(Show.network)
                Text("A station's departures").tag(Show.station)
                Text("The station nearest me").tag(Show.nearest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if model.followsNearestStation {
            nearest
        } else {
            station
        }
        signage
    }

    @ViewBuilder private var signage: some View {
        SettingsGroup(title: "Signage",
                      footer: "The biggest stations get a split-flap departures board; commuter stations, an amber board of trains and times; metro and light rail stations, an amber countdown with each line’s colour and name. Times come from the timetable, corrected by live data where the feeds have it.") {
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

    /// Following the user: which systems' stations count, and what it found.
    @ViewBuilder private var nearest: some View {
        SettingsGroup(title: "Nearest station",
                      footer: "Your location is only compared with Trainspace’s own station list; it isn’t sent anywhere. Within 5 miles of a station you’ve chosen; farther away, the network map around you.") {
            HStack {
                Text(nearestStatus).font(.title3.weight(.semibold))
                Spacer()
            }
            if let message = model.locationMessage {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            Text("Count stations served by").font(.callout).foregroundStyle(.secondary)
            ForEach(model.region.systems, id: \.self) { system in
                Toggle(system.name, isOn: Binding {
                    !model.settings.nearestExcluded.contains(system)
                } set: { on in
                    if on { model.settings.nearestExcluded.remove(system) } else { model.settings.nearestExcluded.insert(system) }
                })
            }
            Divider()
            radius
        }
    }

    private var nearestStatus: String {
        if model.nearestUnavailable { return "No chosen station within 5 miles" }
        guard model.userPosition != nil else { return "Finding you…" }
        guard let i = model.selectedStation, let s = model.rail?.stations[safe: i] else { return "Finding the nearest station…" }
        guard let miles = model.nearestStationMiles else { return s.name }
        return "\(s.name) · \(miles < 0.1 ? "here" : String(format: "%.1f mi away", miles))"
    }

    private var radius: some View {
        HStack(spacing: 12) {
            Text("Map radius")
            Slider(value: $model.settings.stationZoomMiles, in: WallpaperSettings.stationZoomRange)
            Text(String(format: "%.1f mi", model.settings.stationZoomMiles))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder private var station: some View {
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
            radius
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
