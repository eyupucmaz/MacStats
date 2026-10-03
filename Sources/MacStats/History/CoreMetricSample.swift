import Foundation

/// Ids of the series `StatsEngine` records on every tick. Detail-only samplers use
/// their own ids in the same dotted style (e.g. "disk.read", "fan.rpm.1").
enum MetricSeriesID {
    static let cpuTotal = "cpu.total"
    static let cpuUser = "cpu.user"
    static let cpuSystem = "cpu.system"
    static let gpuUtilization = "gpu.utilization"
    static let memoryUsed = "memory.used"
    static let memoryPressure = "memory.pressure"
    static let batteryLevel = "battery.level"
    static let diskUsed = "disk.used"
    static let networkDown = "network.down"
    static let networkUp = "network.up"
    static let fanRPM = "fan.rpm"
    static let temperaturePrimary = "temperature.primary"
}

/// The values one engine tick contributes to the history. Nil means the metric was
/// not measured this tick (no baseline yet, sensor missing, query failed); it is
/// skipped rather than recorded as 0, so charts never show invented values.
struct CoreMetricSample: Equatable {
    var date: Date
    var cpuTotal: Double? = nil
    var cpuUser: Double? = nil
    var cpuSystem: Double? = nil
    var gpuUtilization: Double? = nil
    var memoryUsed: Double? = nil
    var memoryPressure: Double? = nil
    var batteryLevel: Double? = nil
    var diskUsed: Double? = nil
    var networkDown: Double? = nil
    var networkUp: Double? = nil
    var fanRPM: Double? = nil
    var temperature: Double? = nil

    /// Built from the raw reading, not the snapshot: the snapshot keeps the previous
    /// value of a metric that was not measured, which history must not repeat.
    init(reading: StatsReading, date: Date) {
        self.date = date
        cpuTotal = reading.cpuUsage
        cpuUser = reading.cpuUser
        cpuSystem = reading.cpuSystem
        gpuUtilization = reading.gpuUsage
        // A failed VM query reports 0 bytes used, which no running Mac does.
        if reading.memoryUsed > 0 {
            memoryUsed = Double(reading.memoryUsed)
            memoryPressure = reading.memoryPressure
        }
        if StatsSnapshot(batteryLevel: reading.batteryLevel, batteryState: reading.batteryState).isBatteryAvailable {
            batteryLevel = Double(reading.batteryLevel)
        }
        if let disk = reading.disk, disk.totalBytes > 0 {
            diskUsed = Double(disk.usedBytes)
        }
        networkDown = reading.network?.downBytesPerSecond
        networkUp = reading.network?.upBytesPerSecond
        fanRPM = reading.fanRPM.map(Double.init)
        temperature = reading.temperature
    }

    /// Calls `body` for every measured value, without allocating.
    func forEachValue(_ body: (_ id: String, _ unit: MetricUnit, _ value: Double) -> Void) {
        func emit(_ value: Double?, _ id: String, _ unit: MetricUnit) {
            if let value { body(id, unit, value) }
        }
        emit(cpuTotal, MetricSeriesID.cpuTotal, .percent)
        emit(cpuUser, MetricSeriesID.cpuUser, .percent)
        emit(cpuSystem, MetricSeriesID.cpuSystem, .percent)
        emit(gpuUtilization, MetricSeriesID.gpuUtilization, .percent)
        emit(memoryUsed, MetricSeriesID.memoryUsed, .memory)
        emit(memoryPressure, MetricSeriesID.memoryPressure, .percent)
        emit(batteryLevel, MetricSeriesID.batteryLevel, .percent)
        emit(diskUsed, MetricSeriesID.diskUsed, .bytes)
        emit(networkDown, MetricSeriesID.networkDown, .bytesPerSecond)
        emit(networkUp, MetricSeriesID.networkUp, .bytesPerSecond)
        emit(fanRPM, MetricSeriesID.fanRPM, .rpm)
        emit(temperature, MetricSeriesID.temperaturePrimary, .celsius)
    }
}
