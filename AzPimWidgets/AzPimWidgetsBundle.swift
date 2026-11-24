import SwiftUI
import WidgetKit

@main
struct AzPimWidgetsBundle: WidgetBundle {
    var body: some Widget { SpikeWidget() }
}

struct SpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "spike", provider: SpikeProvider()) { _ in Text("AzPim") }
    }
}

struct SpikeProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
