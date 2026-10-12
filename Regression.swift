import Foundation

/// 纯数据回归，不依赖机器是否插电或电量；失败返回非零退出码。
func runRegressionTests() {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
        print("PASS: \(name)")
    }
    let battery: [String: Any] = [
        "Voltage": 12000, "InstantAmperage": NSNumber(value: UInt64.max - 499),
        "CurrentCapacity": 73, "MaxCapacity": 100,
        "ExternalConnected": false, "IsCharging": false,
        "BatteryData": ["CurrentCapacity": 3000, "FullChargeCapacity": 4400,
                        "DesignCapacity": 4600, "AvgTimeToEmpty": 65535],
        "PowerTelemetryData": ["SystemLoad": 6000, "BatteryPower": -6000]
    ]
    let raw = BatteryReader.parse(battery)
    let s = BatteryReader.build(raw)
    check(raw.amperage == -500, "UInt64 补码电流正确解码")
    check(s.capacity == 73, "顶层百分比不被子字典 mAh 覆盖")
    check(s.fullCapacity == 4400 && s.designCapacity == 4600, "健康容量使用 mAh")
    check(s.timeRemaining == 0, "未知剩余时间哨兵不显示为 1092 小时")
    check(s.valid && s.watts == 6 && s.batteryWatts == -6, "电池遥测保留符号和单位")
    var charging = battery
    charging["ExternalConnected"] = true
    charging["IsCharging"] = false
    charging["ChargerData"] = ["IsCharging": true]
    charging["InstantAmperage"] = 2000
    charging["PowerTelemetryData"] = ["SystemLoad": 8000, "SystemPowerIn": 32000,
                                      "BatteryPower": 24000]
    let plugged = BatteryReader.build(BatteryReader.parse(charging))
    check(plugged.watts == 8 && plugged.adapterWatts == 32, "充电 24W 不冒充系统负载 8W")
    check(!plugged.isCharging, "顶层 false 优先于子字典旧充电状态")
    charging.removeValue(forKey: "PowerTelemetryData")
    check(!BatteryReader.build(BatteryReader.parse(charging)).valid,
          "接电且无 SystemLoad 时不伪造整机功耗")
    var legacy = battery
    legacy["CurrentCapacity"] = 2200
    legacy["MaxCapacity"] = 4400
    check(BatteryReader.build(BatteryReader.parse(legacy)).capacity == 50, "旧机 mAh 容量换算百分比")
    var noVoltage = BatteryReader.Raw()
    noVoltage.load = 10000
    check(BatteryReader.build(noVoltage).watts == 10, "系统负载不依赖电池电压存在")
    var zero = BatteryReader.Raw()
    zero.load = 0
    zero.externalConnected = true
    check(BatteryReader.build(zero).valid && BatteryReader.build(zero).watts == 0,
          "零功率是有效测量而非缺失")
    var fallback = BatteryReader.Raw()
    fallback.voltage = 12000
    fallback.amperage = -500
    check(BatteryReader.build(fallback).watts == 6, "无遥测时使用电池放电估算")
    check(!BatteryReader.build(BatteryReader.Raw()).valid, "空数据不能变成有效零瓦")
    check(SMC.decode([0x0c, 0xfe], "si16") == -500, "Apple Silicon 有符号 SMC 解码")
    check(SMC.decode([0x80, 0x3e], "ui16") == 16000, "SMC 电压解码")
    check(SMC.decode([0x19, 0x80], "sp78") == 25.5, "sp78 大端固定点解码")
    check(SMC.decode([0xff, 0x80], "sp78") == -0.5, "sp78 负温度解码")
    check(SMC.decode([1], "ui32") == nil, "短 SMC 数据不会越界")
    check(SMC.decode([0, 0], "????") == nil, "不猜测未知 SMC 格式")
    let batteryOnly = BatteryReader.build(BatteryReader.parse(charging))
    check(!batteryOnly.valid && batteryOnly.hasBatteryData && batteryOnly.hasCapacity,
          "系统功率缺失时仍保留电池信息")
    var chargingStatus = PowerSample()
    chargingStatus.isCharging = true
    check(chargingStatus.menuTitle == "充电中", "充电时无系统负载也显示充电中")
    chargingStatus.isCharging = false
    chargingStatus.valid = true
    chargingStatus.watts = 6.8
    check(chargingStatus.menuTitle == "6.8W", "非充电时保留紧凑功率数字")
    chargingStatus.valid = false
    check(chargingStatus.menuTitle == "--", "功率缺失清除旧菜单读数")
    let m = Monitor()
    m.interval = 0
    check(m.interval >= 0.1, "刷新间隔为零不除零")
    m.interval = .nan
    check(m.interval.isFinite, "拒绝 NaN 刷新间隔")
    print("\(count) regression checks passed")
}
