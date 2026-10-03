import Foundation

/// History series the GPU page records itself, on top of the core `gpu.utilization`
/// the engine records every tick. Each is registered only once a reading has it, so a
/// Mac whose driver does not report them spends no history slot.
enum GPUDetailSeries {
    static let renderer = "gpu.renderer"
    static let tiler = "gpu.tiler"

    /// Records the chart GPU's renderer and tiler readings. Main thread only.
    static func record(_ report: GPUDetailReport, in history: MetricHistory, interval: TimeInterval,
                       at date: Date = Date()) {
        guard let statistics = report.chartGPU?.statistics else { return }
        for (id, value) in [(renderer, statistics.renderer), (tiler, statistics.tiler)] {
            guard let value, history.register(id, unit: .percent, interval: interval) else { continue }
            history.record(value, for: id, unit: .percent, at: date)
        }
    }
}

/// One label / value row of the GPU page.
struct GPUDetailRow: Equatable, Identifiable {
    let label: String
    let value: String
    let spoken: String

    var id: String { label }
}

/// The GPU page's text, kept out of the views so the wording and the "hide what is
/// missing" rules are unit-tested. Text comes from `L10n`; `locale` only decides how
/// numbers are written.
enum GPUDetailPresentation {

    static func percent(_ value: Double, digits: Int = 1, locale: Locale) -> String {
        MetricFormat.percent(value, digits: digits, locale: locale)
    }

    static func spokenPercent(_ value: Double, locale: Locale) -> String {
        MetricValueFormat.spoken(value, unit: .percent, locale: locale)
    }

    /// Chart legend and VoiceOver names of the three lines.
    static var chartLabels: [String: String] {
        [MetricSeriesID.gpuUtilization: L10n.string("Overall"),
         GPUDetailSeries.renderer: L10n.string("Renderer"),
         GPUDetailSeries.tiler: L10n.string("Tiler")]
    }

    /// The model, else the Metal name, else just "GPU".
    static func name(of gpu: GPUDevice) -> String {
        gpu.model ?? gpu.metalName ?? L10n.string("GPU")
    }

    /// A GPU's own utilization for the list on Macs with several: "12.5%", or a dash.
    static func utilization(of gpu: GPUDevice, locale: Locale) -> (text: String, spoken: String) {
        guard let value = gpu.statistics?.utilization else {
            return (MetricFormat.unavailable, L10n.string("Unavailable"))
        }
        return (percent(value, locale: locale), spokenPercent(value, locale: locale))
    }

    /// "Apple M5, 21.0 percent" for VoiceOver.
    static func spokenGPU(_ gpu: GPUDevice, locale: Locale) -> String {
        let name = name(of: gpu)
        let value = utilization(of: gpu, locale: locale).spoken
        return L10n.string("\(name), \(value)")
    }

    // MARK: - Memory

    /// In use, allocated and video memory, each hidden when the driver does not report it.
    static func memoryRows(_ statistics: GPUStatistics?, locale: Locale = .autoupdatingCurrent) -> [GPUDetailRow] {
        guard let statistics else { return [] }
        var rows: [GPUDetailRow] = []
        func add(_ label: String, _ bytes: UInt64?) {
            guard let bytes else { return }
            rows.append(GPUDetailRow(label: label, value: MemoryDetailFormat.bytes(bytes, locale: locale),
                                     spoken: MemoryDetailFormat.spokenBytes(bytes, locale: locale)))
        }
        add(L10n.string("In use"), statistics.memoryInUse)
        add(L10n.string("Allocated"), statistics.memoryAllocated)
        if let used = statistics.videoMemoryUsed {
            let label = L10n.string("Video memory")
            if let total = statistics.videoMemoryTotal, total >= used {
                let spokenUsed = MemoryDetailFormat.spokenBytes(used, locale: locale)
                let spokenTotal = MemoryDetailFormat.spokenBytes(total, locale: locale)
                rows.append(GPUDetailRow(
                    label: label,
                    value: "\(MemoryDetailFormat.bytes(used, locale: locale)) / \(MemoryDetailFormat.bytes(total, locale: locale))",
                    spoken: L10n.string("\(spokenUsed), total \(spokenTotal)")))
            } else {
                add(label, used)
            }
        }
        return rows
    }

    /// Shown once in the memory section when any GPU is Apple silicon.
    static func showsUnifiedMemoryNote(_ report: GPUDetailReport) -> Bool {
        report.gpus.contains(where: \.isAppleSilicon)
    }

    // MARK: - About

    /// Model, core count and Metal name, each hidden when unknown. The model row is left
    /// out when the GPU's name already heads its block (Macs with several GPUs).
    static func aboutRows(_ gpu: GPUDevice, includeModel: Bool) -> [GPUDetailRow] {
        var rows: [GPUDetailRow] = []
        if includeModel, let model = gpu.model {
            rows.append(GPUDetailRow(label: L10n.string("Model"), value: model, spoken: model))
        }
        if let cores = gpu.coreCount {
            rows.append(GPUDetailRow(label: L10n.string("GPU cores"), value: String(cores), spoken: String(cores)))
        }
        if let metal = gpu.metalName {
            rows.append(GPUDetailRow(label: L10n.string("Metal device"), value: metal, spoken: metal))
        }
        return rows
    }
}
