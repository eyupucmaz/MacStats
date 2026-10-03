import SwiftUI

/// What the System tab shows: the card grid, or one metric's detail page.
enum SystemRoute: Equatable {
    case grid
    case detail(MenuBarMetric)
}

/// The System tab's navigation state. Owned by `AppDelegate` rather than
/// `StatsView` so closing the popover can return it to the grid; the view only
/// reads it and calls `open`/`back`.
@MainActor
final class DetailNavigation: ObservableObject {
    @Published private(set) var route: SystemRoute = .grid

    /// One curve for every push and pop; Reduce Motion swaps the slide for a
    /// fade in `StatsView`, not the timing.
    static let animation = Animation.easeInOut(duration: 0.22)

    func open(_ metric: MenuBarMetric) {
        route = .detail(metric)
    }

    /// Also called when the popover closes, so the next open starts at the grid.
    func back() {
        guard route != .grid else { return }
        route = .grid
    }
}

extension MenuBarMetric {
    /// The detail page title: the card's word, spelled out where the card abbreviates it.
    var detailTitle: String {
        switch self {
        case .cpu: return L10n.string("CPU")
        case .gpu: return L10n.string("GPU")
        case .ram: return L10n.string("Memory")
        case .disk: return L10n.string("Disk")
        case .network: return L10n.string("Network")
        case .battery: return L10n.string("Battery")
        case .fan: return L10n.string("Fan")
        case .temp: return L10n.string("Temperature")
        }
    }

    /// The card for this metric, so a page header shows exactly what the card did.
    func card(_ s: StatsSnapshot, locale: Locale = .autoupdatingCurrent) -> StatCardModel {
        switch self {
        case .cpu: return StatCardFactory.cpu(s, locale: locale)
        case .gpu: return StatCardFactory.gpu(s, locale: locale)
        case .ram: return StatCardFactory.memory(s, locale: locale)
        case .disk: return StatCardFactory.disk(s, locale: locale)
        case .network: return StatCardFactory.network(s, locale: locale)
        case .battery: return StatCardFactory.battery(s)
        case .fan: return StatCardFactory.fan(s)
        case .temp: return StatCardFactory.temperature(s, locale: locale)
        }
    }
}

extension StatCardModel {
    /// Card identifiers are the `MenuBarMetric` raw values.
    var metric: MenuBarMetric? { MenuBarMetric(rawValue: id) }
}
