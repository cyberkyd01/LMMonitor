// SystemSampler.swift
// 1 Hz system metrics: CPU (total + P/E), GPU (IOAccelerator), memory, swap, pressure, disk,
// thermal, battery, SoC power (PowerSampler) and engine / LM Studio process footprints.
//
// P/E ordering: on Apple Silicon the E cluster is enumerated first. Verified on this M3 Max via
// `ioreg -p IODeviceTree` (cluster-type "E" for logical-cpu-id 0...3, "P" for 4...13), so
// E = logical CPUs 0..<hw.perflevel1.logicalcpu and P = the rest.
//
// All mutable state lives on `queue`; the sink is called on the main actor with an immutable copy.

import Foundation
import IOKit
import IOKit.ps
import Darwin

final class SystemSampler {
    static let engineNeedle = "/.lmstudio/extensions/backends/"
    static let appNeedle = "/LM Studio.app/Contents/"

    private let queue = DispatchQueue(label: "lmmonitor.sampler", qos: .utility)
    private let power: PowerSampler?
    private let sink: @MainActor @Sendable (SystemSnapshot) -> Void
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 1.0

    // CPU
    private var prevCPUTicks: [UInt32] = []
    private let eCount: Int
    private let pCount: Int

    // Disk
    private var prevDisk: (read: UInt64, write: UInt64, at: UInt64)?

    // Processes
    private var enginePIDHint: Int32?
    private var enginePIDs: [Int32] = []
    private var appPIDs: [Int32] = []
    private var lastRescan: UInt64 = 0
    private var prevProc: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]

    init(power: PowerSampler?, sink: @escaping @MainActor @Sendable (SystemSnapshot) -> Void) {
        self.power = power
        self.sink = sink
        self.eCount = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        self.pCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
    }

    func start(interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = max(0.25, interval)
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.sample() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func setEnginePID(_ pid: Int32?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enginePIDHint = pid
            if let pid, !self.enginePIDs.contains(pid) { self.enginePIDs.append(pid) }
        }
    }

    /// Test hook: last measured cost of sample() in ms (queue-confined).
    private(set) var lastCostMs: Double = 0
    var onCost: ((Double) -> Void)?

    // MARK: sample

    private func sample() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var snap = SystemSnapshot()
        snap.sampledAt = Date()
        snap.pCoreCount = pCount
        snap.eCoreCount = eCount
        readCPU(&snap)
        readGPU(&snap)
        snap.gpuBudgetBytes = GPUBudget.effectiveBudgetBytes
        readMemory(&snap)
        readDisk(&snap)
        snap.thermal = ProcessInfo.processInfo.thermalState
        snap.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        readBattery(&snap)
        if let p = power, p.isAvailable { snap.power = p.sample() }
        readProcesses(&snap)
        let out = snap
        lastCostMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        onCost?(lastCostMs)
        hopToMain { [sink] in sink(out) }
    }

    // MARK: CPU

    private func readCPU(_ snap: inout SystemSnapshot) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        let n = Int(cpuCount) * stride
        var ticks = [UInt32](repeating: 0, count: n)
        for i in 0..<n { ticks[i] = UInt32(bitPattern: info[i]) }
        let prev = prevCPUTicks
        prevCPUTicks = ticks
        guard prev.count == n else { return }

        var busyAll = 0.0, totAll = 0.0, busyE = 0.0, totE = 0.0, busyP = 0.0, totP = 0.0
        for cpu in 0..<Int(cpuCount) {
            let b = cpu * stride
            let u = Double(ticks[b + Int(CPU_STATE_USER)] &- prev[b + Int(CPU_STATE_USER)])
            let s = Double(ticks[b + Int(CPU_STATE_SYSTEM)] &- prev[b + Int(CPU_STATE_SYSTEM)])
            let ni = Double(ticks[b + Int(CPU_STATE_NICE)] &- prev[b + Int(CPU_STATE_NICE)])
            let id = Double(ticks[b + Int(CPU_STATE_IDLE)] &- prev[b + Int(CPU_STATE_IDLE)])
            let busy = u + s + ni, tot = busy + id
            busyAll += busy; totAll += tot
            if cpu < eCount { busyE += busy; totE += tot } else { busyP += busy; totP += tot }
        }
        if totAll > 0 { snap.cpuPercent = busyAll / totAll * 100 }
        if totE > 0 { snap.cpuECorePercent = busyE / totE * 100 }
        if totP > 0 { snap.cpuPCorePercent = busyP / totP * 100 }
    }

    // MARK: GPU

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private func readGPU(_ snap: inout SystemSnapshot) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var dev: Double?, ren: Double?, til: Double?, inUse: Double?, alloc: Double?
        while case let e = IOIteratorNext(iter), e != 0 {
            defer { IOObjectRelease(e) }
            guard let props = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let v = Self.num(props["Device Utilization %"]) ?? Self.num(props["GPU Activity(%)"]) { dev = max(dev ?? 0, v) }
            if let v = Self.num(props["Renderer Utilization %"]) { ren = max(ren ?? 0, v) }
            if let v = Self.num(props["Tiler Utilization %"]) { til = max(til ?? 0, v) }
            if let v = Self.num(props["In use system memory"]) { inUse = (inUse ?? 0) + v }
            if let v = Self.num(props["Alloc system memory"]) { alloc = (alloc ?? 0) + v }
        }
        snap.gpuPercent = dev
        snap.gpuRendererPercent = ren
        snap.gpuTilerPercent = til
        snap.gpuInUseBytes = inUse.map { UInt64(max(0, $0)) }
        snap.gpuAllocBytes = alloc.map { UInt64(max(0, $0)) }
    }

    // MARK: memory / swap / pressure

    private func readMemory(_ snap: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            snap.memUsedBytes = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            snap.memWiredBytes = UInt64(stats.wire_count) * page
            snap.memCompressedBytes = UInt64(stats.compressor_page_count) * page
            snap.memFreeBytes = (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * page
        }
        var lvl: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &sz, nil, 0) == 0 {
            snap.memPressure = MemoryPressure(rawValue: Int(lvl)) ?? .unknown
        }
        var sw = xsw_usage()
        var swSz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &swSz, nil, 0) == 0 {
            snap.swapUsedBytes = sw.xsu_used
            snap.swapTotalBytes = sw.xsu_total
        }
    }

    // MARK: disk

    private func readDisk(_ snap: inout SystemSnapshot) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0, any = false
        while case let e = IOIteratorNext(iter), e != 0 {
            defer { IOObjectRelease(e) }
            guard let st = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            any = true
            if let v = Self.num(st["Bytes (Read)"]) { r &+= UInt64(max(0, v)) }
            if let v = Self.num(st["Bytes (Write)"]) { w &+= UInt64(max(0, v)) }
        }
        guard any else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let p = prevDisk, now > p.at, r >= p.read, w >= p.write {
            let dt = Double(now - p.at) / 1e9
            snap.diskReadBps = Double(r - p.read) / dt
            snap.diskWriteBps = Double(w - p.write) / dt
        }
        prevDisk = (r, w, now)
    }

    // MARK: battery

    private func readBattery(_ snap: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            snap.onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            if let cur = d[kIOPSCurrentCapacityKey] as? Int {
                let mx = (d[kIOPSMaxCapacityKey] as? Int) ?? 100
                snap.batteryPercent = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
            }
            return
        }
    }

    // MARK: processes

    private func readProcesses(_ snap: inout SystemSnapshot) {
        let nowT = DispatchTime.now().uptimeNanoseconds
        if lastRescan == 0 || nowT &- lastRescan >= 10_000_000_000 {
            lastRescan = nowT
            let g = ProcessStats.pids(groups: [[Self.engineNeedle], [Self.appNeedle]])
            var eng = g[0]
            let app = g[1]
            if let h = enginePIDHint, !eng.contains(h), kill(h, 0) == 0 { eng.append(h) }
            enginePIDs = eng
            appPIDs = app
        }
        snap.engine = footprint(name: "Engine", pids: &enginePIDs, now: nowT)
        snap.lmStudio = footprint(name: "LM Studio", pids: &appPIDs, now: nowT)
        // Drop stale CPU baselines.
        let live = Set(enginePIDs + appPIDs)
        if prevProc.count > live.count { prevProc = prevProc.filter { live.contains($0.key) } }
    }

    private func footprint(name: String, pids: inout [Int32], now: UInt64) -> ProcessFootprint? {
        var alive: [Int32] = []
        var bytes: UInt64 = 0
        var cpuPct: Double?
        for pid in pids {
            guard let u = ProcessStats.usage(pid: pid) else { continue }
            alive.append(pid)
            bytes &+= u.physFootprint
            if let p = prevProc[pid], now > p.at, u.cpuTimeNs >= p.cpuNs {
                cpuPct = (cpuPct ?? 0) + Double(u.cpuTimeNs - p.cpuNs) / Double(now - p.at) * 100
            }
            prevProc[pid] = (u.cpuTimeNs, now)
        }
        pids = alive
        guard !alive.isEmpty else { return nil }
        return ProcessFootprint(name: name, pids: alive, physFootprintBytes: bytes, cpuPercent: cpuPct)
    }

    // MARK: util

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
        return Int(v)
    }
}
