import SwiftUI

/// The Network card's page (#30): live rates, the download/upload history, session and
/// boot totals, each interface in use, and the Wi-Fi link's radio details.
///
/// Rates and the chart come from the engine (`network.down` / `network.up`); everything
/// below them from `NetworkDetailSampler`, which runs only while the page is visible.
/// Public IP and per-process traffic are out of scope by design (#20).
struct NetworkDetailPage: View {
    @EnvironmentObject private var stats: StatsEngine
    @StateObject private var model = NetworkDetailModel()
    @State private var range = HistoryRange.default

    var body: some View {
        DetailPage(metric: .network, range: $range) {
            NetworkRateHeadline(down: stats.snapshot.networkDownBytes, up: stats.snapshot.networkUpBytes)
            NetworkThroughputSection(history: stats.history, range: range)
            if let report = model.report {
                NetworkTotalsSection(report: report)
                NetworkInterfacesSection(interfaces: report.interfaces)
                if let wifi = report.wifi {
                    NetworkWiFiSection(wifi: wifi)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// Owns the page's sampler and publishes its reports.
@MainActor
final class NetworkDetailModel: ObservableObject {
    @Published private(set) var report: NetworkDetailReport?
    private let sampler = NetworkDetailSampler()

    func start() {
        sampler.start { [weak self] report in
            guard let self, self.report != report else { return }
            self.report = report
        }
    }

    func stop() {
        sampler.stop()
    }
}

// MARK: - Headline

private struct NetworkRateHeadline: View {
    let down: Double
    let up: Double

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            rate(L10n.string("Download"), value: down, icon: "arrow.down.circle.fill")
            rate(L10n.string("Upload"), value: up, icon: "arrow.up.circle.fill")
        }
    }

    private func rate(_ title: String, value: Double, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteRate.short(value, locale: locale))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("\(title), \(ByteRate.spoken(value, locale: locale))"))
    }
}

// MARK: - Chart

/// Observes the history store, so only this section redraws on each tick.
private struct NetworkThroughputSection: View {
    @ObservedObject var history: MetricHistory
    let range: HistoryRange

    var body: some View {
        let download = L10n.string("Download")
        let upload = L10n.string("Upload")
        let series = [MetricSeriesID.networkDown, MetricSeriesID.networkUp].compactMap {
            history.series($0, range: range)
        }
        DetailSection(L10n.string("Throughput")) {
            MetricChart(title: L10n.string("Download and upload"),
                        series: series,
                        labels: [MetricSeriesID.networkDown: download, MetricSeriesID.networkUp: upload],
                        style: .line,
                        range: range)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.networkDown, range: range),
                           unit: .bytesPerSecond, title: download)
            SeriesStatsRow(statistics: history.statistics(MetricSeriesID.networkUp, range: range),
                           unit: .bytesPerSecond, title: upload)
        }
    }
}

// MARK: - Totals

private struct NetworkTotalsSection: View {
    let report: NetworkDetailReport

    @Environment(\.locale) private var locale

    var body: some View {
        let sinceStartTitle = L10n.string("Since MacStats started")
        let sinceBootTitle = L10n.string("Since boot")
        let sinceStart = NetworkDetailFormat.totals(report.sinceStart, title: sinceStartTitle, locale: locale)
        let sinceBoot = NetworkDetailFormat.totals(report.sinceBoot, title: sinceBootTitle, locale: locale)
        if sinceStart != nil || sinceBoot != nil {
            DetailSection(L10n.string("Totals")) {
                if let sinceStart { PairRow(title: sinceStartTitle, pair: sinceStart) }
                if let sinceBoot { PairRow(title: sinceBootTitle, pair: sinceBoot) }
            }
        }
    }
}

/// "Title   ↓value   ↑value" as one VoiceOver element. Fixed value columns keep the
/// arrows of consecutive rows aligned.
private struct PairRow: View {
    let title: String
    let pair: NetworkDetailFormat.Pair

    static let valueWidth: CGFloat = 76

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(pair.down)
                .frame(width: Self.valueWidth, alignment: .trailing)
            Text(pair.up)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pair.spoken)
    }
}

/// "Title   value", the value right-aligned and selectable (addresses get copied).
private struct ValueRow: View {
    let title: String
    let value: String
    var spoken: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("\(title), \(spoken ?? value)"))
    }
}

// MARK: - Interfaces

private struct NetworkInterfacesSection: View {
    let interfaces: [NetworkInterfaceDetail]

    var body: some View {
        DetailSection(L10n.string("Interfaces")) {
            if interfaces.isEmpty {
                DetailUnavailableView(title: L10n.string("No network connection"),
                                      reason: L10n.string("Interfaces appear here when this Mac is connected to a network."),
                                      icon: "wifi.slash")
            } else {
                ForEach(Array(interfaces.enumerated()), id: \.element.id) { index, interface in
                    if index > 0 { Divider() }
                    NetworkInterfaceView(interface: interface)
                }
            }
        }
    }
}

private struct NetworkInterfaceView: View {
    let interface: NetworkInterfaceDetail

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: NetworkDetailFormat.kindIcon(interface.kind))
                    .foregroundStyle(.teal)
                    .frame(width: 16)
                Text(NetworkDetailFormat.kind(interface.kind))
                    .font(.subheadline.weight(.semibold))
                Text(interface.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if interface.isPrimary {
                    Text(L10n.string("Primary"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.teal.opacity(0.2), in: Capsule())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NetworkDetailFormat.spokenInterface(interface))
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 3) {
                PairRow(title: L10n.string("Now"),
                        pair: NetworkDetailFormat.rates(down: interface.downRate, up: interface.upRate,
                                                        title: L10n.string("Now"), locale: locale))
                if let row = NetworkDetailFormat.totals(interface.sinceStart, title: L10n.string("Since MacStats started"),
                                                        locale: locale) {
                    PairRow(title: L10n.string("Since MacStats started"), pair: row)
                }
                if let row = NetworkDetailFormat.totals(interface.sinceBoot, title: L10n.string("Since boot"),
                                                        locale: locale) {
                    PairRow(title: L10n.string("Since boot"), pair: row)
                }
                ForEach(interface.addresses.ipv4, id: \.self) { address in
                    ValueRow(title: L10n.string("IPv4"), value: address)
                }
                ForEach(interface.addresses.ipv6, id: \.self) { address in
                    ValueRow(title: L10n.string("IPv6"), value: address)
                }
                if let speed = interface.linkSpeed {
                    ValueRow(title: L10n.string("Link speed"),
                             value: NetworkDetailFormat.bitRate(Double(speed), locale: locale),
                             spoken: NetworkDetailFormat.spokenBitRate(Double(speed), locale: locale))
                }
            }
        }
    }
}

// MARK: - Wi-Fi

private struct NetworkWiFiSection: View {
    let wifi: WiFiDetails

    @Environment(\.locale) private var locale

    var body: some View {
        DetailSection(L10n.string("Wi-Fi")) {
            VStack(alignment: .leading, spacing: 3) {
                if let name = wifi.networkName {
                    ValueRow(title: L10n.string("Network name"), value: name)
                }
                if let rssi = wifi.rssi {
                    ValueRow(title: L10n.string("Signal"), value: NetworkDetailFormat.dBm(rssi),
                             spoken: NetworkDetailFormat.spokenDBm(rssi))
                }
                if let noise = wifi.noise {
                    ValueRow(title: L10n.string("Noise"), value: NetworkDetailFormat.dBm(noise),
                             spoken: NetworkDetailFormat.spokenDBm(noise))
                }
                if let rate = wifi.transmitRate {
                    ValueRow(title: L10n.string("Transmit rate"),
                             value: NetworkDetailFormat.bitRate(rate * 1e6, locale: locale),
                             spoken: NetworkDetailFormat.spokenBitRate(rate * 1e6, locale: locale))
                }
                if let channel = wifi.channel {
                    ValueRow(title: L10n.string("Channel"),
                             value: NetworkDetailFormat.channel(channel, band: wifi.band))
                }
            }
        }
    }
}
