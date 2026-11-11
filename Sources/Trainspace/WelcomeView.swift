import SwiftUI
import TrainspaceCore

/// First run: pick a place while a live preview fills in.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private let previewSize = CGSize(width: 560, height: 330)

    var body: some View {
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
                Text("Metrorail and Baltimore’s Light Rail and Subway run on the timetable until you add free API keys in Settings › Live Data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Set as Wallpaper") {
                    model.completeOnboarding(with: model.settings.location)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.mapCenter == nil)
            }
        }
        .padding(28)
        .frame(width: previewSize.width + 56)
        .onAppear { model.beginPreview() }
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
