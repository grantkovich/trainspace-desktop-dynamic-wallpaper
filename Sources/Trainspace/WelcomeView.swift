import SwiftUI
import TrainspaceCore

/// First run: pick a place while a live preview fills in, then (where a region has them) the
/// optional API keys a person can request for live data.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var step: Step
    @Environment(\.dismiss) private var dismiss

    enum Step: String, CaseIterable { case place, keys }

    init(model: AppModel, initialStep: Step = .place) {
        self.model = model
        _step = State(initialValue: initialStep)
    }

    private let previewSize = CGSize(width: 560, height: 330)

    var body: some View {
        Group {
            switch step {
            case .place: placeStep
            case .keys: keysStep
            }
        }
        .padding(28)
        .frame(width: previewSize.width + 56)
        .onAppear { model.beginPreview() }
    }

    private var regionNeedsKeys: Bool { !LiveFeeds.KeyKind.kinds(for: model.region).isEmpty }

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TRAINSPACE")
                    .font(.system(size: 26, weight: .semibold).width(.expanded))
                    .tracking(6)
                Text("Every train in DC–Baltimore, New York, Philadelphia and Boston, live, as your wallpaper.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            preview

            VStack(alignment: .leading, spacing: 10) {
                RegionPicker(model: model).pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack(spacing: 8) {
                    ForEach(model.region.presets) { preset in
                        Button(preset.name) { model.choose(preset) }
                            .controlSize(.large)
                    }
                }
                HStack(spacing: 8) {
                    Text("Or a station’s departure boards:").foregroundStyle(.secondary)
                    ForEach(model.region.featured, id: \.self) { name in
                        if let s = model.rail?.stations.first(where: { $0.name == name }) {
                            Button(name) { model.show(station: s) }
                        }
                    }
                }
                HStack {
                    Button {
                        model.useSystemLocation()
                    } label: {
                        Label("Use My Location", systemImage: "location.fill")
                    }
                    .controlSize(.large)
                    TextField("Zip code, neighborhood, station, or coordinates", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit { model.setPlace(query: query) }
                    Button("Preview") { model.setPlace(query: query) }
                        .controlSize(.large)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message = model.locationMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                } else if model.isOutsideRegion {
                    Text("That’s outside the DC–Baltimore rail network. Pick one of the places above, or somewhere closer.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            HStack {
                if regionNeedsKeys {
                    Text("Next: optional free keys for live Metrorail and Baltimore’s Light RailLink and Metro SubwayLink.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Every live feed here works without an account or key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set as Wallpaper") {
                    model.completeOnboarding(with: model.settings.location)
                    if regionNeedsKeys { step = .keys } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.mapCenter == nil)
            }
        }
    }

    /// Optional keys. The wallpaper is already running behind this, on the timetable for
    /// these lines, so skipping loses nothing but live positions.
    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LIVE DATA")
                    .font(.system(size: 26, weight: .semibold).width(.expanded))
                    .tracking(6)
                Text("Optional. Some railways only share live positions with people who have their own free key.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Without a key, those lines still show, placed by the timetable and drawn hollow. Keys are yours: Trainspace saves them in your keychain, sends each one only to its own feed, and never shares them. You can add or change them later in Settings › Live Data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) { APIKeyList(model: model) }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            HStack {
                Button("Back") { step = .place }
                Spacer()
                Button(model.apiKeys.isEmpty ? "Skip for Now" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    private var preview: some View {
        TrainspaceView(model: model, size: CGSize(width: previewSize.width * 2, height: previewSize.height * 2), insets: EdgeInsets())
            .scaleEffect(0.5, anchor: .topLeading)
            .frame(width: previewSize.width, height: previewSize.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .overlay {
                if model.mapCenter == nil {
                    VStack(spacing: 8) {
                        if model.isResolvingLocation { ProgressView() }
                        Text(model.isResolvingLocation ? "Finding you…" : "Choose a place to preview")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
}
