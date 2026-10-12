import Cocoa
import SwiftUI
import IOKit

// ============================================================
//  功率计 PowerMeter  —  macOS 菜单栏实时功耗显示
//
//  双通道取数：
//    ① IOKit 直读 AppleSmartBattery 属性（亚毫秒，首选）
//    ② ioreg 子进程（回退通道，约 10ms）
//
//  关键字段（PowerTelemetryData）：
//    SystemLoad      系统负载遥测   (mW)
//    SystemPowerIn   适配器输入功率 (mW)
//    BatteryPower    电池功率       (mW，负=放电 正=充电)
//  备用算法：Voltage(mV) × InstantAmperage(mA)
//
//  全程只读、无需 sudo、无第三方依赖。
// ============================================================

// MARK: - 采样数据

struct PowerSample {
    var watts: Double = 0            // W  展示用主读数
    var smcWatts: Double? = nil      // W  来自 SMC（B0AC×B0AV），约 1 秒刷新
    var telemetryWatts: Double = 0   // W  来自 SystemLoad（芯片平滑遥测，更新偏慢）
    var instantWatts: Double = 0     // W  来自 V × I（瞬时，但同样受 8~17 秒刷新限制）
    var adapterWatts: Double = 0     // W  适配器输入功率
    var batteryWatts: Double = 0     // W  电池功率（负=放电，正=充电）
    var voltage: Double = 0          // V
    var amperage: Double = 0         // A （负=放电）
    var capacity: Int = 0            // %
    var fullCapacity: Int = 0        // mAh
    var designCapacity: Int = 0      // mAh
    var externalConnected: Bool = false
    var isCharging: Bool = false
    var timeRemaining: Int = 0       // 分钟
    var valid: Bool = false
    var source = "--"
    var hasTelemetry = false
    var hasBatteryPower = false
    var hasCapacity = false
    var hasVoltage = false
    var hasAmperage = false

    var hasBatteryData: Bool { hasCapacity || hasVoltage || hasAmperage || fullCapacity > 0 || externalConnected }
    var menuTitle: String {
        if isCharging { return "充电中" }
        return valid ? String(format: "%.1fW", watts) : "--"
    }

    /// 电池健康度 = 满充容量 / 设计容量
    var health: Double? {
        guard designCapacity > 0, fullCapacity > 0 else { return nil }
        return Double(fullCapacity) / Double(designCapacity) * 100
    }
}

// MARK: - 取数

enum BatteryReader {

    /// 与取数通道无关的原始读数
    struct Raw {
        var voltage: Double?        // mV
        var amperage: Double?       // mA（有符号）
        var load: Double?           // mW
        var powerIn: Double?        // mW
        var batteryPower: Double?   // mW
        var capacity: Int?
        var fullCapacity: Int?
        var designCapacity: Int?
        var timeToEmpty: Int?
        var externalConnected = false
        var isCharging = false
    }

    // ---------- 通道 ① IOKit 直读 ----------

    private static func cfBool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    private static func rawFromIOKit() -> Raw? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return parse(dict)
    }

    /// 两个通道共用解析器，避免正则从不同层级抓到同名但不同单位的字段。
    static func parse(_ dict: [String: Any]) -> Raw {
        func num(_ d: [String: Any], _ key: String, signed: Bool = false) -> Double? {
            guard let n = d[key] as? NSNumber else { return nil }
            // ioreg 的 plist 可能用 UInt64 的补码表示负电流/功率。
            let value = signed ? Double(n.int64Value) : n.doubleValue
            return value.isFinite ? value : nil
        }
        func int(_ d: [String: Any], _ key: String) -> Int? {
            guard let v = num(d, key), v >= 0, v < Double(Int.max) else { return nil }
            return Int(v)
        }
        let bd = dict["BatteryData"] as? [String: Any] ?? [:]
        let tele = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        var r = Raw()
        r.voltage = num(dict, "Voltage")
        r.amperage = num(dict, "InstantAmperage", signed: true)
            ?? num(dict, "Amperage", signed: true)
        // CurrentCapacity / MaxCapacity 是一对；旧机器可能使用 mAh 而不是百分比。
        let capacityDict = num(dict, "CurrentCapacity") != nil ? dict : bd
        let current = num(capacityDict, "CurrentCapacity")
        let maximum = num(capacityDict, "MaxCapacity") ?? num(capacityDict, "FullChargeCapacity")
        if let current, let maximum, maximum > 0, current >= 0 {
            r.capacity = Int(min(100, max(0, current / maximum * 100)).rounded())
        }
        r.fullCapacity = int(bd, "FullChargeCapacity") ?? int(dict, "AppleRawMaxCapacity")
            ?? int(dict, "FullChargeCapacity")
        r.designCapacity = int(bd, "DesignCapacity") ?? int(dict, "DesignCapacity")
        r.timeToEmpty = int(bd, "AvgTimeToEmpty") ?? int(dict, "AvgTimeToEmpty")
        if let time = r.timeToEmpty, time >= 65535 { r.timeToEmpty = nil }
        r.load = num(tele, "SystemLoad", signed: true)
        r.powerIn = num(tele, "SystemPowerIn", signed: true)
        r.batteryPower = num(tele, "BatteryPower", signed: true)
            ?? num(bd, "BatteryPower", signed: true) ?? num(dict, "BatteryPower", signed: true)
        r.externalConnected = cfBool(dict["ExternalConnected"])
        // 顶层字段优先；false 也是有效状态，不能被子字典里的旧值覆盖。
        r.isCharging = cfBool(dict["IsCharging"]
            ?? (dict["ChargerData"] as? [String: Any])?["IsCharging"])
        return r
    }

    // ---------- 通道 ② ioreg 子进程 ----------

    private static func rawFromProcess() -> Raw? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-a", "-r", "-c", "AppleSmartBattery"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // 回退进程卡住时最多等待两秒；不让后台读数永远占住 reading 标志。
        let timeout = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timeout.cancel()
        guard proc.terminationStatus == 0,
              let roots = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [[String: Any]], let dict = roots.first else { return nil }
        return parse(dict)
    }

    // ---------- 组装 ----------

    static func build(_ r: Raw) -> PowerSample {
        var s = PowerSample()
        s.voltage = (r.voltage ?? 0) / 1000
        s.amperage = (r.amperage ?? 0) / 1000
        s.capacity = r.capacity ?? 0
        s.hasCapacity = r.capacity != nil
        s.hasVoltage = r.voltage.map { $0.isFinite && $0 > 0 } ?? false
        s.hasAmperage = r.amperage.map { $0.isFinite } ?? false
        s.fullCapacity = r.fullCapacity ?? 0
        s.designCapacity = r.designCapacity ?? 0
        s.timeRemaining = r.timeToEmpty ?? 0
        s.externalConnected = r.externalConnected
        s.isCharging = r.isCharging
        s.hasTelemetry = r.load.map { $0.isFinite && $0 >= 0 } ?? false
        s.telemetryWatts = s.hasTelemetry ? r.load! / 1000 : 0
        s.adapterWatts = max(0, r.powerIn ?? 0) / 1000
        let hasVI = s.voltage.isFinite && s.voltage > 0 && r.amperage != nil && s.amperage.isFinite
        s.instantWatts = hasVI ? abs(s.voltage * s.amperage) : 0
        s.hasBatteryPower = r.batteryPower != nil || hasVI
        s.batteryWatts = r.batteryPower.map { $0 / 1000 } ?? (hasVI ? s.voltage * s.amperage : 0)
        // 接电时电池功率表示充放电，适配器输入也包含充电和损耗，都不能冒充系统负载。
        if s.hasTelemetry {
            s.watts = s.telemetryWatts
            s.source = "系统遥测"
            s.valid = true
        } else if !s.externalConnected, s.hasBatteryPower {
            s.watts = abs(s.batteryWatts)
            s.source = "电池估算"
            s.valid = true
        }
        return s
    }

    // ---------- 通道 ③ SMC 直读（刷新最快，约 1 秒）----------

    private static let smc: SMC? = SMC()

    /// 从 SMC 读瞬时功率：B0AC(电池电流 mA) × B0AV(电池电压 mV)
    /// AppleSmartBattery 每 8~17 秒才刷新，而 SMC 约 1 秒刷新一次。
    static func readSMCWatts() -> Double? {
        guard let smc else { return nil }
        guard let amps = smc.readNumber("B0AC"),     // mA，负=放电
              let volts = smc.readNumber("B0AV"),    // mV
              volts > 1000, volts < 30000 else { return nil }
        let w = abs(amps * volts) / 1_000_000.0      // mA × mV → W
        guard w.isFinite, w >= 0, w < 300 else { return nil }
        return w
    }

    /// 读取一次，并返回实际使用的通道
    static func read() -> (sample: PowerSample, channel: String) {
        var sample = PowerSample()
        var channel = "读取失败"

        if let r = rawFromIOKit() {
            sample = build(r)
            channel = "IOKit"
        } else if let r = rawFromProcess() {
            sample = build(r)
            channel = "ioreg"
        }
        if !sample.valid { channel += "（系统负载不可用）" }

        if sample.valid, !sample.externalConnected, let w = readSMCWatts() {
            sample.smcWatts = w
            sample.watts = w
            sample.source = "SMC 电池估算"
            channel += " + SMC"
        }
        return (sample, channel)
    }

    /// 自检专用：强制走子进程通道，用于交叉核对
    static func readViaProcessForCheck() -> PowerSample {
        guard let r = rawFromProcess() else { return PowerSample() }
        return build(r)
    }
}

// MARK: - 监控中心

final class Monitor: ObservableObject {

    @Published private(set) var sample = PowerSample()
    @Published private(set) var history: [Double] = []
    @Published private(set) var channel = "--"

    /// 显示数值最后变化的时刻；稳定读数不能据此判定传感器是否陈旧。
    @Published private(set) var lastChangeAt = Date()
    private var lastValue = -1.0

    @Published var interval: Double = 1.0 {
        didSet {
            if !interval.isFinite || interval < 0.1 || interval > 60 {
                interval = oldValue.isFinite && oldValue >= 0.1 && oldValue <= 60 ? oldValue : 1
            }
            if timer != nil { restartTimer() }
        }
    }

    var onUpdate: ((PowerSample) -> Void)?
    private var timer: Timer?
    private var reading = false
    @Published private(set) var historyDates: [Date] = []
    private var lastHistoryAt = Date.distantPast
    private var lastSource = ""
    private let samplingQueue = DispatchQueue(label: "com.yixian.powermeter.sampling", qos: .utility)

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        tick()
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = min(0.1, interval * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var windowSeconds: Int {
        guard let first = historyDates.first, let last = historyDates.last else { return 0 }
        return max(0, Int(last.timeIntervalSince(first).rounded()))
    }

    private func tick() {
        guard !reading else { return }
        reading = true
        // 放到后台队列，避免阻塞主线程影响弹窗动画
        samplingQueue.async { [weak self] in
            let (raw, ch) = BatteryReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                let s = raw
                self.sample = s
                self.channel = ch
                let now = Date()
                // 故障或来源切换后断开曲线，避免把充电/电池等不同测量口径连在一起。
                if !s.valid || s.isCharging || s.source != self.lastSource || now.timeIntervalSince(self.lastHistoryAt) > 65 {
                    self.history.removeAll()
                    self.historyDates.removeAll()
                    self.lastValue = -1
                }
                self.lastSource = s.source
                if s.valid && !s.isCharging {
                    if abs(s.watts - self.lastValue) > 0.01 {
                        self.lastValue = s.watts
                        self.lastChangeAt = now
                    }
                    // 高频只加快数字刷新；曲线最多每 0.5 秒保存一个点。
                    if now.timeIntervalSince(self.lastHistoryAt) >= 0.5 || self.history.isEmpty {
                        self.lastHistoryAt = now
                        self.history.append(s.watts)
                        self.historyDates.append(now)
                    }
                    while let first = self.historyDates.first, now.timeIntervalSince(first) > 60 {
                        self.historyDates.removeFirst()
                        self.history.removeFirst()
                    }
                }
                self.onUpdate?(s)
                self.reading = false
            }
        }
    }

    /// 仅供离屏 UI 检查，不改变真实供电状态。
    func setPreviewSample(_ value: PowerSample) {
        stop()
        sample = value
        history.removeAll()
        historyDates.removeAll()
    }

    /// 仅供自检渲染：以真实读数为基准填充一段模拟历史
    func seedHistoryForPreview(base: Double) {
        let b = base > 0 ? base : 8.0
        historyDates = (0..<120).map { Date().addingTimeInterval(Double($0 - 119) * 0.5) }
        history = (0..<120).map { i in
            max(1.0, b + sin(Double(i) / 7.0) * 1.4 + Double.random(in: -1.1...1.1))
        }
    }
}

// MARK: - 开机自启

enum LoginItem {
    static let label = "com.yixian.powermeter"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            let exe = Bundle.main.executablePath ?? ""
            guard !exe.isEmpty else { return }
            let plist: [String: Any] = [
                "Label": label, "ProgramArguments": [exe],
                "RunAtLoad": true, "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
        }
    }
}

// MARK: - App 主控

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private var lastClose = Date.distantPast
    private var activity: NSObjectProtocol?
    var debugCheckPopover = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⚠️ 关键：本应用只驻菜单栏、平时没有可见窗口，
        //    系统会判定为空闲而施加 App Nap，把定时器降频到数秒一次。
        //    必须声明为持续活动状态，刷新频率才真正生效。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "菜单栏实时功率监控")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "--"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let host = NSHostingController(rootView: PowerView(monitor: monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        syncPopoverSize()

        monitor.onUpdate = { [weak self] s in
            self?.refreshTitle(s)
        }
        monitor.start()

        if debugCheckPopover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.togglePopover(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.reportPopoverGeometry()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 校验 popover 窗口是否装得下 SwiftUI 内容（装不下就会裁掉顶部）
    private func reportPopoverGeometry() {
        guard let vc = popover.contentViewController else {
            print("✗ 没有 contentViewController"); return
        }
        vc.view.layoutSubtreeIfNeeded()
        let content = vc.view.fittingSize
        print("popover.contentSize  = \(Int(popover.contentSize.width)) × \(Int(popover.contentSize.height))")
        print("内容实际 fittingSize  = \(Int(content.width)) × \(Int(content.height))")
        if let win = vc.view.window {
            print("窗口 frame           = \(Int(win.frame.width)) × \(Int(win.frame.height))")
            print("窗口 contentView     = \(Int(win.contentView?.frame.width ?? 0)) × \(Int(win.contentView?.frame.height ?? 0))")
            let need = content.height
            let have = win.contentView?.frame.height ?? 0
            print(have + 0.5 >= need
                  ? "✓ 窗口高度 \(Int(have)) ≥ 内容 \(Int(need))，内容完整"
                  : "✗ 窗口高度 \(Int(have)) < 内容 \(Int(need))，会被裁掉 \(Int(need - have)) pt")
        } else {
            print("✗ popover 未显示，拿不到窗口")
        }
    }

    /// 让 popover 尺寸跟随 SwiftUI 内容的真实尺寸，
    /// 否则 AppKit 会拿一个偏小的旧尺寸，导致顶部内容被裁掉。
    private func syncPopoverSize() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        if fit.width > 10, fit.height > 10 {
            popover.contentSize = fit
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }

    private func refreshTitle(_ s: PowerSample) {
        guard let button = statusItem.button else { return }
        let text = s.menuTitle
        let title = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        button.attributedTitle = title
        button.toolTip = s.isCharging ? "充电中" : (s.valid
            ? "系统功耗：\(String(format: "%.1f", s.watts)) W · \(s.source)" : "系统负载不可用")
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // transient 模式下"点图标关闭"会先自动关闭再触发本方法，需拦截这次重开
            if Date().timeIntervalSince(lastClose) < 0.25 { return }
            syncPopoverSize()          // 每次打开前按真实内容尺寸校准，避免内容被裁
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    runRegressionTests()
    exit(0)
}

// 自检：PowerMeter --dump  打印一次读数，并与子进程通道交叉核对
if CommandLine.arguments.contains("--dump") {
    func show(_ tag: String, _ s: PowerSample) {
        guard s.valid else { print("── \(tag)\n   读取失败"); return }
        print("── \(tag)")
        print(String(format: "   系统功耗   : %.2f W", s.watts))
        if let smcW = s.smcWatts {
            print(String(format: "   SMC 瞬时   : %.2f W   (B0AC × B0AV，约 1 秒刷新)", smcW))
        }
        print(String(format: "   电压 × 电流: %.2f V × %.2f A", s.voltage, s.amperage))
        print(String(format: "   电池功率   : %+.2f W", s.batteryWatts))
        if s.adapterWatts > 0.01 {
            print(String(format: "   适配器输入 : %.2f W", s.adapterWatts))
        }
        let st = s.externalConnected ? (s.isCharging ? "充电中" : "已接电源") : "电池供电"
        print("   供电状态   : \(st)")
        var line = "   电池       : \(s.capacity)%  \(s.fullCapacity)/\(s.designCapacity) mAh"
        if let h = s.health { line += String(format: "  健康度 %.1f%%", h) }
        print(line)
    }

    let (s, ch) = BatteryReader.read()
    print("当前通道：\(ch)\n")
    show("最终结果", s)

    let viaProcess = BatteryReader.readViaProcessForCheck()
    if viaProcess.valid {
        print("")
        show("交叉核对（ioreg 子进程）", viaProcess)
        let diff = abs(viaProcess.telemetryWatts - s.telemetryWatts)
        print("\n比较同一 SystemLoad 字段；SMC 与系统遥测采样时刻不同，不用于通道一致性判断。")
        print(String(format: "\nSystemLoad 通道偏差: %.3f W  →  %@",
                     diff, diff < 0.3 ? "✓ 两通道一致" : "✗ 两通道不一致"))
    }
    exit(0)
}

// 自检：PowerMeter --watch [次数] [间隔秒]  逐拍打印两个功率源的响应差异
if let idx = CommandLine.arguments.firstIndex(of: "--watch") {
    let n = max(1, min(10000, idx + 1 < CommandLine.arguments.count
        ? (Int(CommandLine.arguments[idx + 1]) ?? 30) : 30))
    let requestedDT = idx + 2 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[idx + 2]) ?? 0.2) : 0.2

    let dt = requestedDT.isFinite ? min(60, max(0.1, requestedDT)) : 1

    print("  时刻      V×I(瞬时)   SystemLoad(遥测)     偏差")
    print("  ------   ----------   ----------------   --------")
    let t0 = Date()
    var lastInstant = -1.0
    var lastTelemetry = -1.0
    for _ in 0..<n {
        let (s, _) = BatteryReader.read()
        let t = Date().timeIntervalSince(t0)

        let dI = lastInstant < 0 ? 0 : abs(s.instantWatts - lastInstant)
        let dT = lastTelemetry < 0 ? 0 : abs(s.telemetryWatts - lastTelemetry)
        lastInstant = s.instantWatts
        lastTelemetry = s.telemetryWatts

        print(String(format: "%6.1f s   %8.3f W   %12.3f W   %+7.3f W   Δ瞬时%.3f Δ遥测%.3f",
                     t, s.instantWatts, s.telemetryWatts,
                     s.instantWatts - s.telemetryWatts, dI, dT))
        Thread.sleep(forTimeInterval: dt)
    }
    exit(0)
}

// 自检：PowerMeter --bench  测量取数速度，用于评估可用刷新频率
if CommandLine.arguments.contains("--bench") {
    let n = 2000
    let t0 = Date()
    for _ in 0..<n { _ = BatteryReader.read() }
    let dt = Date().timeIntervalSince(t0)
    let per = dt / Double(n) * 1000

    print(String(format: "IOKit 直读 %d 次，总耗时 %.3f s", n, dt))
    print(String(format: "单次耗时        : %.3f ms", per))
    print("")
    for interval in [0.2, 0.5, 1.0] {
        print(String(format: "%.1f 秒间隔 取数墙钟时间占比: %.3f%%",
                     interval, per / (interval * 1000) * 100))
    }
    exit(0)
}

// 自检：PowerMeter --uitest  离屏渲染弹出面板为 PNG
if CommandLine.arguments.contains("--uitest") {
    _ = NSApplication.shared
    let m = Monitor()
    m.start()

    // 首次读取走后台队列；多等一会儿让取数完成并积累真实历史
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    let previewMode = CommandLine.arguments.contains("--charging") ? "charging"
        : (CommandLine.arguments.contains("--unavailable") ? "unavailable" : "normal")
    if previewMode != "normal" {
        var raw = BatteryReader.Raw()
        raw.voltage = 12000
        raw.amperage = previewMode == "charging" ? 1000 : 0
        raw.capacity = 80
        raw.fullCapacity = 4400
        raw.designCapacity = 4600
        raw.externalConnected = true
        raw.isCharging = previewMode == "charging"
        m.setPreviewSample(BatteryReader.build(raw))
    } else if m.history.count < 8, m.sample.valid, !m.sample.isCharging {
        m.seedHistoryForPreview(base: m.sample.watts)
    }

    let dark = CommandLine.arguments.contains("--dark")
    let host = NSHostingController(rootView: PowerView(monitor: m)
        .environment(\.colorScheme, dark ? .dark : .light))
    let size = host.view.fittingSize

    // cacheDisplay 不会画窗口背景，这里补一个容器底，才能看清深色模式下的文字
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    container.layer?.backgroundColor = (dark
        ? NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
        : NSColor.white).cgColor

    host.view.frame = container.bounds
    container.addSubview(host.view)
    container.layoutSubtreeIfNeeded()

    if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
        container.cacheDisplay(in: container.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let suffix = previewMode == "normal" ? "" : "_\(previewMode)"
            let out = "/tmp/powerview\(suffix)\(dark ? "_dark" : "").png"
            try? png.write(to: URL(fileURLWithPath: out))
            print("UI 渲染成功：\(Int(size.width))×\(Int(size.height)) → \(out)")
        }
    }
    exit(0)
}

// 自检：PowerMeter --popovertest  真实弹出 popover 并核对窗口/内容尺寸
if CommandLine.arguments.contains("--popovertest") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.debugCheckPopover = true
    app.delegate = delegate
    app.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // 只驻菜单栏，不占 Dock
app.run()
