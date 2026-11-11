import SwiftUI
import TrainspaceCore

/// The optional API keys for a region, one card each. Used by the welcome window and
/// Settings › Live Data.
struct APIKeyList: View {
    @Bindable var model: AppModel

    var body: some View {
        let kinds = LiveFeeds.KeyKind.kinds(for: model.region)
        ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
            if index > 0 { Divider() }
            APIKeyCard(model: model, kind: kind)
        }
    }
}

/// One key: what it turns live, how to get your own, a field to paste it, and whether it works.
struct APIKeyCard: View {
    @Bindable var model: AppModel
    let kind: LiveFeeds.KeyKind
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(systemNames).font(.headline)
                Spacer()
                FeedBadge(status: status)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(kind.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Link("Open \(kind.signupName)", destination: kind.signupURL)
                .font(.callout)
            KeyField(title: kind.title, text: $text) { model.setAPIKey(text, for: kind) }
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .onAppear { text = model.apiKeys[kind] ?? "" }
    }

    private var systemNames: String {
        kind.systems.map(\.name).formatted(.list(type: .and))
    }

    /// The feeds behind one key share a fate, so the first one speaks for the key.
    private var status: FeedStatus? { kind.systems.lazy.compactMap { model.feeds[$0] }.first }

    private var message: (text: String, isProblem: Bool)? {
        guard model.apiKeys[kind] != nil else { return nil }
        if status?.error == "Key not accepted" {
            return ("That key wasn’t accepted. Check it was copied whole, or request a new one.", true)
        }
        if status?.mode == .live { return ("Saved in your keychain. Live.", false) }
        return ("Saved in your keychain. Checking it with the feed…", false)
    }
}
