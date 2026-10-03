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
    /// The popover's segment. Kept here rather than in `StatsView`'s `@State` so
    /// `AppDelegate` can switch to the System tab before showing a page (#33).
    /// Unlike `route`, closing the popover leaves it alone.
    @Published var tab: PopoverTab = .system

    /// One curve for every push and pop; Reduce Motion swaps the slide for a
    /// fade in `StatsView`, not the timing.
    static let animation = Animation.easeInOut(duration: 0.22)

    func open(_ metric: MenuBarMetric) {
        route = .detail(metric)
    }

    /// Opens a page on the System tab, wherever the popover was left; used when
    /// the popover opens straight onto a page rather than from a card.
    func show(_ metric: MenuBarMetric) {
        if tab != .system { tab = .system }
        open(metric)
    }

    /// Also called when the popover closes, so the next open starts at the grid.
    func back() {
        guard route != .grid else { return }
        route = .grid
    }
}

/// What opened the popover, which decides the System tab route it opens on.
enum PopoverOpenTrigger: Equatable {
    /// A left-click (or VoiceOver press) on the status item.
    case statusItem
    /// A metric chosen from the status menu's Details submenu.
    case detailsMenu(MenuBarMetric)
    /// The one-time first-launch open that shows the welcome hint.
    case onboarding
}

extension DetailNavigation {
    /// The route the popover opens on. A pure function of the trigger and the
    /// settings so it can be tested without a status item.
    ///
    /// A click opens a page only when the user asked for it and the menu bar
    /// shows exactly one metric: with several the click is ambiguous, with
    /// none there is nothing to pick.
    static func initialRoute(
        for trigger: PopoverOpenTrigger,
        menuBarMetrics: [MenuBarMetric],
        opensSingleMetricDetails: Bool
    ) -> SystemRoute {
        switch trigger {
        case .detailsMenu(let metric):
            return .detail(metric)
        case .statusItem:
            guard opensSingleMetricDetails, menuBarMetrics.count == 1, let only = menuBarMetrics.first else {
                return .grid
            }
            return .detail(only)
        case .onboarding:
            // The welcome hint sits above the grid; a page would bury it.
            return .grid
        }
    }
}

/// One entry of the status menu's Details submenu.
struct DetailsMenuItem: Equatable {
    let metric: MenuBarMetric
    let title: String
    /// SF Symbol, the same one the metric's card shows.
    let symbol: String
}

enum DetailsMenu {
    /// The submenu's title; also the Settings section that configures it.
    static var title: String { L10n.string("Details") }

    /// Every metric in card order, whether or not its card is shown: the menu
    /// is a way in to the pages, not a mirror of the grid.
    static var items: [DetailsMenuItem] {
        MenuBarMetric.allCases.map { DetailsMenuItem(metric: $0, title: $0.detailTitle, symbol: $0.symbol) }
    }
}

extension MenuBarMetric {
    /// The card's SF Symbol without a snapshot. Battery's card symbol follows
    /// the charge, so the menu shows it full.
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .battery: return "battery.100"
        case .fan: return "fanblades"
        case .temp: return "thermometer"
        }
    }

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
