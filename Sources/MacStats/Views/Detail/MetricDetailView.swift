import SwiftUI

/// The detail page for each card. Each metric's issue (#25–#32) replaces its
/// placeholder line with the real page.
struct MetricDetailView: View {
    let metric: MenuBarMetric

    var body: some View {
        switch metric {
        case .cpu: CPUDetailPage()
        case .gpu: GPUDetailPage()
        case .ram: MemoryDetailPage()
        case .disk: DiskDetailPage()
        case .network: NetworkDetailPage()
        case .battery: BatteryDetailPage()
        case .fan: FanDetailPage()
        case .temp: TemperatureDetailPage()
        }
    }
}

/// Header plus a "coming soon" note, so every card opens something until its page lands.
struct DetailPlaceholderPage: View {
    let metric: MenuBarMetric

    static var title: String { L10n.string("Details coming soon") }
    static var reason: String { L10n.string("Charts and a breakdown of this number will appear here.") }

    var body: some View {
        DetailPage(metric: metric) {
            DetailUnavailableView(title: Self.title, reason: Self.reason, icon: "chart.xyaxis.line")        }
    }
}
