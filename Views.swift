import SwiftUI

// ============================================================
//  弹窗界面
// ============================================================

/// 本地偏好设置
/// 集中管理开机启动设置和操作失败反馈。
final class Prefs: ObservableObject {
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    @Published var loginError: String?
}

// 图形主色（不跟随系统强调色，避免用户设成"石墨色"后曲线发灰）
private let curveColor = Color(red: 0.16, green: 0.48, blue: 0.96)

struct PowerView: View {

    @ObservedObject var monitor: Monitor
    @StateObject private var prefs = Prefs()

    private var s: PowerSample { monitor.sample }

    // 数值统一格式化
    private func f(_ format: String, _ value: Double) -> String {
        value.isFinite ? String(format: format, value) : "--"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chartSection
            metricsSection
            settingsSection
        }
        // 固定尺寸：让 NSPopover 的 contentSize 有确定值，
        // 否则 AppKit 会沿用偏小的旧尺寸，导致顶部内容被裁掉。
        .frame(width: 320, height: 450)
    }

    /// 数据源新鲜度与来源。
    /// AppleSmartBattery 每 8~17 秒才更新，SMC 约 1 秒更新，如实标出来。
    private var freshnessText: String {
        if s.isCharging { return "功耗曲线已暂停" }
        guard monitor.sample.valid else { return "遥测不可用" }
        let src = s.smcWatts != nil ? "SMC" : "系统"
        let age = Int(Date().timeIntervalSince(monitor.lastChangeAt))
        if age <= 1 { return "\(src) · 刚变化" }
        return "\(src) · \(age) 秒未变化"
    }

    // ---------- 顶部：主读数 ----------

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.isCharging ? "供电状态" : (s.source.contains("估算") ? "系统功耗（电池估算）" : "系统功耗"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if s.isCharging {
                    Text("充电中")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                } else {
                    Text(s.valid ? String(format: "%.1f", s.watts) : "--")
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(s.watts > 20 ? Color.orange : Color.primary)
                    Text("W")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 54, alignment: .leading)

            statusLine
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if !s.hasBatteryData { return .gray }
        if s.isCharging { return .green }
        if s.externalConnected { return .blue }
        return .orange
    }

    private var statusText: String {
        guard s.hasBatteryData else { return "电池信息不可用" }
        let capacity = s.hasCapacity ? "\(s.capacity)%" : "电量未知"
        if s.isCharging { return "电池电量 · \(capacity)" }
        if s.externalConnected { return "已接电源 · \(capacity)" }
        return "电池供电 · 剩余 \(fmtTime(s.timeRemaining))"
    }

    // ---------- 曲线 ----------

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Sparkline(values: s.isCharging ? [] : monitor.history, dates: monitor.historyDates,
                      emptyText: s.isCharging ? "充电时暂停功耗曲线" : (s.valid ? "正在采集数据…" : "系统负载不可用"))
                .frame(height: 66)

            HStack(spacing: 0) {
                Text(s.isCharging ? "未记录功耗" : (monitor.history.count > 1 ? "近 \(monitor.windowSeconds) 秒" : "暂无曲线"))
                Spacer()
                Text(freshnessText)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // ---------- 指标网格 ----------

    private var metricsSection: some View {
        let items = metricItems
        return VStack(spacing: 0) {
            Divider()
            VStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 12) {
                        metric(items[row * 2].0, items[row * 2].1)
                        metric(items[row * 2 + 1].0, items[row * 2 + 1].1)
                    }
                }
            }
            .padding(.vertical, 12)
            Divider()
        }
        .padding(.horizontal, 16)
    }

    private var metricItems: [(String, String)] {
        var fifth: (String, String)
        if s.adapterWatts > 0.01 {
            fifth = ("适配器输入", f("%.2f W", s.adapterWatts))
        } else {
            fifth = (abs(s.batteryWatts) < 0.01 ? "电池功率" : (s.batteryWatts > 0 ? "电池充电" : "电池放电"),
                     s.hasBatteryPower ? f("%.2f W", abs(s.batteryWatts)) : "--")
        }
        return [
            ("电池电量", s.hasCapacity ? "\(s.capacity)%" : "--"),
            ("电池健康", s.health.map { String(format: "%.1f%%", $0) } ?? "--"),
            ("电压", s.hasVoltage ? f("%.2f V", s.voltage) : "--"),
            ("电流（正充负放）", s.hasAmperage ? f("%+.2f A", s.amperage) : "--"),
            fifth,
            ("电池容量", s.fullCapacity > 0 ? "\(s.fullCapacity) mAh" : "--"),
        ]
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ---------- 设置 ----------

    private var settingsSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("刷新间隔")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $monitor.interval) {
                    Text("0.1s").tag(0.1)
                    Text("0.5s").tag(0.5)
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 196)
            }

            HStack {
                Toggle(isOn: $prefs.launchAtLogin) {
                    Text("开机自动启动").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: prefs.launchAtLogin) { _, on in
                    guard on != LoginItem.isEnabled else { return }
                    do { try LoginItem.setEnabled(on) }
                    catch {
                        prefs.launchAtLogin = LoginItem.isEnabled
                        prefs.loginError = error.localizedDescription
                    }
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .semibold))
                        Text("退出").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .alert("无法修改开机启动", isPresented: Binding(
            get: { prefs.loginError != nil },
            set: { if !$0 { prefs.loginError = nil } }
        )) {
            Button("好") { prefs.loginError = nil }
        } message: {
            Text(prefs.loginError ?? "")
        }
    }

    private func fmtTime(_ minutes: Int) -> String {
        guard minutes > 0 else { return "时间待估算" }
        return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分钟" : "\(minutes)分钟"
    }
}

// ============================================================
//  功耗曲线
// ============================================================

struct Sparkline: View {

    var values: [Double]
    var dates: [Date] = []
    var emptyText = "正在采集数据…"

    /// 纵轴满量程：向上取整到整数瓦。
    /// 关键：不要直接用 max × 1.3，否则最大值每帧微变都会让曲线整体上下跳。
    static func peak(for values: [Double]) -> Double {
        let m = values.max() ?? 5
        return max(5, (m * 1.12).rounded(.up))
    }

    private var peak: Double { Self.peak(for: values) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 5
            let usable = h - pad * 2
            let n = values.count
            let step = n > 1 ? w / CGFloat(n - 1) : w

            ZStack {
                // 横向参考线（25% / 50% / 75%）
                ForEach([0.25, 0.5, 0.75], id: \.self) { p in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: pad + usable * p))
                        path.addLine(to: CGPoint(x: w, y: pad + usable * p))
                    }
                    .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
                }

                if n > 1 {
                    let pts: [CGPoint] = values.enumerated().map { i, v in
                        let duration = dates.count == n ? dates[n - 1].timeIntervalSince(dates[0]) : 0
                        let x = duration > 0 ? w * CGFloat(dates[i].timeIntervalSince(dates[0]) / duration)
                            : CGFloat(i) * step
                        return CGPoint(x: x, y: pad + usable * (1 - min(max(v, 0) / peak, 1)))
                    }

                    // 面积渐变
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [curveColor.opacity(0.28), curveColor.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom))

                    // 折线
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(curveColor,
                            style: StrokeStyle(lineWidth: 1.7,
                                               lineCap: .round, lineJoin: .round))

                    // 当前值圆点
                    Circle()
                        .fill(curveColor)
                        .frame(width: 5, height: 5)
                        .position(pts[pts.count - 1])
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .overlay {
            if values.count < 2 {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
