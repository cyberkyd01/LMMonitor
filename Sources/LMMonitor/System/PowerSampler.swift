// PowerSampler.swift
// Rootless CPU/GPU/ANE/DRAM power, GPU frequency and SoC temperatures on Apple Silicon.
// Uses private APIs loaded dynamically (libIOReport, IOKit HID). Every symbol is checked;
// if anything is missing the corresponding fields simply stay nil.
//
// Real channel names observed on M3 Max / macOS 15.8 (group "Energy Model", no subgroup):
//   "CPU Energy" (mJ, aggregate of all clusters), "GPU Energy" (nJ, aggregate of GPU0 + GPU CS0 +
//   GPU SRAM0 + GPU CS SRAM0), "GPU0" (mJ), "ANE0" (mJ), "DRAM0" (mJ), plus per-core EACC_CPUn /
//   PACCx_CPUn, *_CPM, *_SRAM, ECPUDTLxx / PCPUDTLxx, ISP0, AVE0, MSR0, DCS0, AMCC0, DISP0, DISPEXT0,
//   PCIe*. Units differ per channel (mJ / uJ / nJ), so the unit label is always honoured.
//
// Temperatures: on this M3 Max the HID sensors are "PMU tdie1...tdie10" (SoC die, not split by
// CPU/GPU), "PMU tdevN" (device/board), "PMU tcal", "NAND CH0 temp", "gas gauge battery".
// There is no GPU-named HID sensor. Heuristic: cpuTempC = mean of "PMU tdie*"; gpuTempC comes from
// IOReport "GPU Stats"/"Temperature" (Tg*a Sum / Sum Count, centi-degrees); maxTempC = hottest of
// tdie* and the GPU sensors.
//
// GPU frequency: GPU Stats / "GPU Performance States" channel "GPUPH" residencies, weighted with the
// DVFS table in IORegistry pmgr "voltage-states9" (little-endian UInt32 pairs: Hz, voltage). The
// state names are "OFF","P1".."Pn"; Pk maps to table entry k-1 after skipping a leading 0-Hz entry
// if present. If the count doesn't line up, frequency is left nil rather than guessed.

import Foundation
import IOKit


final class PowerSampler {
    private typealias CopyInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeFn = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StrFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias CountFn = @convention(c) (CFDictionary) -> Int32

    private var fCreateSamples: CreateSamplesFn?
    private var fDelta: DeltaFn?
    private var fGroup: StrFn?, fSub: StrFn?, fName: StrFn?, fUnit: StrFn?
    private var fInt: IntFn?
    private var fStateCount: CountFn?
    private var fStateName: ((CFDictionary, Int32) -> Unmanaged<CFString>?)?
    private var fStateRes: IntFn?

    private var subscription: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var prev: CFDictionary?
    private var prevTime: TimeInterval = 0
    private var gpuFreqsMHz: [Double] = []

    // HID
    private typealias HIDCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias HIDSetMatchFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias HIDCopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias HIDCopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias HIDCopyEventFn = @convention(c) (CFTypeRef, Int64, Int64, Int64) -> Unmanaged<CFTypeRef>?
    private typealias HIDFloatFn = @convention(c) (CFTypeRef, Int32) -> Double
    private var hidClient: CFTypeRef?
    private var hCopyServices: HIDCopyServicesFn?
    private var hCopyProp: HIDCopyPropFn?
    private var hCopyEvent: HIDCopyEventFn?
    private var hFloat: HIDFloatFn?

    private(set) var isAvailable: Bool = false

    // HID temperature reads cost ~14 ms (service enumeration), so they are cached and refreshed
    // at most every `hidInterval` seconds; temperatures change slowly anyway.
    private let hidInterval: TimeInterval = 5
    private var lastHIDAt: TimeInterval = 0
    private var cachedDieTemp: Double?
    private var cachedDieMax: Double?

    init() {
        setupIOReport()
        setupHID()
    }

    private func sym<T>(_ h: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private func setupIOReport() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        guard let copyIn = sym(h, "IOReportCopyChannelsInGroup", CopyInGroupFn.self),
              let merge = sym(h, "IOReportMergeChannels", MergeFn.self),
              let createSub = sym(h, "IOReportCreateSubscription", CreateSubFn.self),
              let cSamples = sym(h, "IOReportCreateSamples", CreateSamplesFn.self),
              let cDelta = sym(h, "IOReportCreateSamplesDelta", DeltaFn.self),
              let gGroup = sym(h, "IOReportChannelGetGroup", StrFn.self),
              let gSub = sym(h, "IOReportChannelGetSubGroup", StrFn.self),
              let gName = sym(h, "IOReportChannelGetChannelName", StrFn.self),
              let gUnit = sym(h, "IOReportChannelGetUnitLabel", StrFn.self),
              let gInt = sym(h, "IOReportSimpleGetIntegerValue", IntFn.self)
        else { return }
        fCreateSamples = cSamples; fDelta = cDelta
        fGroup = gGroup; fSub = gSub; fName = gName; fUnit = gUnit; fInt = gInt
        fStateCount = sym(h, "IOReportStateGetCount", CountFn.self)
        if let sn = sym(h, "IOReportStateGetNameForIndex", (@convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?).self) {
            fStateName = { sn($0, $1) }
        }
        fStateRes = sym(h, "IOReportStateGetResidency", IntFn.self)

        guard let energy = copyIn("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        // Optional extras; merge into the energy dictionary.
        if let gpuPS = copyIn("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            merge(energy, gpuPS, nil)
        }
        if let gpuT = copyIn("GPU Stats" as CFString, "Temperature" as CFString, 0, 0, 0)?.takeRetainedValue() {
            merge(energy, gpuT, nil)
        }
        var subbed: Unmanaged<CFMutableDictionary>? = nil
        guard let sub = createSub(nil, energy, &subbed, 0, nil) else {
            subbed?.release()
            return
        }
        subscription = sub
        channels = subbed?.takeRetainedValue() ?? energy
        gpuFreqsMHz = Self.readGPUFreqTableMHz()
        isAvailable = true
    }

    /// DVFS table from IORegistry pmgr "voltage-states9": pairs of LE UInt32 (Hz, voltage).
    private static func readGPUFreqTableMHz() -> [Double] {
        guard let match = IOServiceMatching("AppleARMIODevice") else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var result: [Double] = []
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(e, &nameBuf)
            guard String(cString: nameBuf) == "pmgr" else { continue }
            guard let p = IORegistryEntryCreateCFProperty(e, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let data = p as? Data, data.count >= 8, data.count % 8 == 0 else { continue }
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: data.count, by: 8) {
                    let hz = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                    result.append(Double(UInt32(littleEndian: hz)) / 1_000_000.0)
                }
            }
            break
        }
        return result
    }

    private func setupHID() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        guard let create = sym(h, "IOHIDEventSystemClientCreate", HIDCreateFn.self),
              let setMatch = sym(h, "IOHIDEventSystemClientSetMatching", HIDSetMatchFn.self),
              let copyS = sym(h, "IOHIDEventSystemClientCopyServices", HIDCopyServicesFn.self),
              let copyP = sym(h, "IOHIDServiceClientCopyProperty", HIDCopyPropFn.self),
              let copyE = sym(h, "IOHIDServiceClientCopyEvent", HIDCopyEventFn.self),
              let flt = sym(h, "IOHIDEventGetFloatValue", HIDFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        setMatch(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        hidClient = client
        hCopyServices = copyS; hCopyProp = copyP; hCopyEvent = copyE; hFloat = flt
    }

    private func str(_ f: StrFn?, _ d: CFDictionary) -> String {
        f?(d)?.takeUnretainedValue() as String? ?? ""
    }

    func sample() -> PowerReading {
        var r = PowerReading()
        let up = ProcessInfo.processInfo.systemUptime
        if lastHIDAt == 0 || up - lastHIDAt >= hidInterval {
            var t = PowerReading()
            readHID(&t)
            cachedDieTemp = t.cpuTempC
            cachedDieMax = t.maxTempC
            lastHIDAt = up
        }
        r.cpuTempC = cachedDieTemp
        r.maxTempC = cachedDieMax
        guard isAvailable, let cSamples = fCreateSamples, let delta = fDelta,
              let cur = cSamples(subscription, channels, nil)?.takeRetainedValue() else { return r }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prev = cur; prevTime = now }
        guard let p = prev else { return r }
        let dt = now - prevTime
        guard dt > 0.05, let d = delta(p, cur, nil)?.takeRetainedValue() else { return r }
        guard let arr = (d as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return r }

        var cpu = 0.0, gpuAgg = 0.0, gpu0 = 0.0, ane = 0.0, dram = 0.0
        var haveCPU = false, haveGPUAgg = false, haveGPU0 = false, haveANE = false, haveDRAM = false
        var tSum: [String: Double] = [:], tCnt: [String: Double] = [:]
        var gpuStates: [(String, Double)] = []

        for ch in arr {
            let group = str(fGroup, ch), sub = str(fSub, ch), name = str(fName, ch)
            if group == "Energy Model" {
                let unit = str(fUnit, ch)
                let scale: Double
                switch unit {
                case "mJ": scale = 1e-3
                case "uJ", "µJ": scale = 1e-6
                case "nJ": scale = 1e-9
                default: continue
                }
                let joules = Double(fInt?(ch, 0) ?? 0) * scale
                if name.hasSuffix("CPU Energy") { cpu += joules; haveCPU = true }
                else if name.hasSuffix("GPU Energy") { gpuAgg += joules; haveGPUAgg = true }
                else if name.hasPrefix("GPU") && name.hasSuffix("0") && name == "GPU0" { gpu0 += joules; haveGPU0 = true }
                else if name.hasPrefix("ANE") && !name.contains("_") { ane += joules; haveANE = true }
                else if name.hasPrefix("DRAM") { dram += joules; haveDRAM = true }
            } else if group == "GPU Stats" {
                if sub == "Temperature" {
                    // "TgNa Sum" / "TgNa Sum Count"
                    if name.hasPrefix("Tg"), name.hasSuffix(" Sum Count") {
                        tCnt[String(name.dropLast(" Sum Count".count))] = Double(fInt?(ch, 0) ?? 0)
                    } else if name.hasPrefix("Tg"), name.hasSuffix(" Sum") {
                        tSum[String(name.dropLast(" Sum".count))] = Double(fInt?(ch, 0) ?? 0)
                    }
                } else if sub == "GPU Performance States", name == "GPUPH",
                          let cnt = fStateCount?(ch), let sn = fStateName, let sr = fStateRes {
                    for i in 0..<cnt {
                        gpuStates.append((sn(ch, i)?.takeUnretainedValue() as String? ?? "", Double(sr(ch, i))))
                    }
                }
            }
        }

        if haveCPU { r.cpuWatts = cpu / dt }
        if haveGPUAgg { r.gpuWatts = gpuAgg / dt } else if haveGPU0 { r.gpuWatts = gpu0 / dt }
        if haveANE { r.aneWatts = ane / dt }
        if haveDRAM { r.dramWatts = dram / dt }
        let parts = [r.cpuWatts, r.gpuWatts, r.aneWatts, r.dramWatts].compactMap { $0 }
        if !parts.isEmpty { r.totalWatts = parts.reduce(0, +) }

        // GPU temperature (centi-degC average over the interval)
        var gtemps: [Double] = []
        for (k, s) in tSum { if let c = tCnt[k], c > 0 { gtemps.append(s / c / 100.0) } }
        gtemps = gtemps.filter { $0 > 0 && $0 < 150 }
        if !gtemps.isEmpty {
            r.gpuTempC = gtemps.reduce(0, +) / Double(gtemps.count)
            let m = gtemps.max()!
            r.maxTempC = max(r.maxTempC ?? m, m)
        }

        // GPU frequency
        r.gpuFrequencyMHz = gpuFrequency(gpuStates)
        return r
    }

    private func gpuFrequency(_ states: [(String, Double)]) -> Double? {
        // Active states are those not named OFF/IDLE/DOWN; map the k-th active state to freq table.
        let active = states.filter { !["OFF", "IDLE", "DOWN"].contains($0.0) }
        guard !active.isEmpty else { return nil }
        var table = gpuFreqsMHz
        if table.first == 0 { table.removeFirst() }
        guard table.count >= active.count else { return nil }
        // If the table is longer than the state list, the trailing states are the ones in use.
        // (Not guessing: require an exact match.)
        guard table.count == active.count else { return nil }
        let total = states.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var weighted = 0.0, activeRes = 0.0
        for (i, s) in active.enumerated() { weighted += s.1 * table[i]; activeRes += s.1 }
        guard activeRes > 0 else { return 0 }
        return weighted / activeRes
    }

    private func readHID(_ r: inout PowerReading) {
        guard let client = hidClient, let copyS = hCopyServices, let copyP = hCopyProp,
              let copyE = hCopyEvent, let flt = hFloat,
              let services = copyS(client)?.takeRetainedValue() as [AnyObject]? else { return }
        var die: [Double] = []
        for s in services {
            guard let name = copyP(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  name.hasPrefix("PMU tdie"),
                  let ev = copyE(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let t = flt(ev, 15 << 16)
            if t.isFinite, t > 0, t < 150 { die.append(t) }
        }
        if !die.isEmpty {
            r.cpuTempC = die.reduce(0, +) / Double(die.count)
            r.maxTempC = die.max()
        }
    }
}
