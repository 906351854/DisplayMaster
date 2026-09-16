import Foundation
import CoreGraphics
import IOKit

/// 环境光读数源（可插拔：未来若有直读传感器的通道，替换这里即可）。
///
/// **为什么是「内置屏亮度镜像」而不是直接读传感器：**
/// macOS 27 起第三方进程已经拿不到原始环境光数据 —— 实测三条路全被收死：
/// 1. HID 事件系统：`IOHIDEventSystemClientCopyEvent` 符号已移除，
///    `CopyServices` 对无授权进程永远返回空，事件流里也没有 ALS 事件；
/// 2. SMC：经典 struct 接口对所有用户进程返回 `kIOReturnUnsupported`
///    （原版 smctemp 在 macOS 27 上同样读不出任何键）；
/// 3. IORegistry：AppleALS 节点对用户态不可见。
///
/// 但系统自己的「自动调节亮度」（环境光补偿，ALC）一直在跑，它的调节结果
/// 就落在内置屏的实时亮度上。DisplayServices 把这个值以「线性亮度」暴露
/// 出来 —— 把它当作环境光的代理读数（0…1），系统随光线调内屏 → 读数变化
/// → 外接屏随动。这正是 macOS 对内置屏做的事，只是搬到了外接屏上。
///
/// **降级语义**：内置屏离线（被「自动关内屏」关掉、合盖、台式机没内屏）
/// 或读数失败时返回 nil，由调用方决定是保持现状还是放弃 —— 不猜、不抖动。
enum AmbientLight {
    private static let displayServices = DynamicSymbol.open(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")

    private static let getLinearBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>?) -> Int32)? =
        DynamicSymbol.load("DisplayServicesGetLinearBrightness", from: [displayServices],
                           as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>?) -> Int32).self)
    private static let getLinearRange: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32)? =
        DynamicSymbol.load("DisplayServicesGetLinearBrightnessUsableRange", from: [displayServices],
                           as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32).self)
    private static let hasALC: (@convention(c) (CGDirectDisplayID) -> Bool)? =
        DynamicSymbol.load("DisplayServicesHasAmbientLightCompensation", from: [displayServices],
                           as: (@convention(c) (CGDirectDisplayID) -> Bool).self)

    /// 在线的内置屏 displayID。没有（台式机 / 合盖 / 被关掉）就是 nil。
    private static func onlineBuiltinID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == CGError.success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func linearBrightness(of display: CGDirectDisplayID) -> Double? {
        guard let fn = getLinearBrightness else { return nil }
        var v: Float = -1
        guard fn(display, &v) == 0, v >= 0 else { return nil }
        return Double(v)
    }

    private static func usableRange(of display: CGDirectDisplayID) -> (min: Double, max: Double)? {
        guard let fn = getLinearRange else { return nil }
        var lo: Float = -1, hi: Float = -1
        guard fn(display, &lo, &hi) == 0, hi > lo else { return nil }
        return (Double(lo), Double(hi))
    }

    /// 这台机器的内置屏是否接了环境光补偿管线（菜单是否值得展示这个开关）。
    /// 注意这是「系统能力」判断，不代表此刻内置屏在线。
    static var sensorPathAvailable: Bool {
        guard let builtin = onlineBuiltinID(), let has = hasALC else { return false }
        return has(builtin)
    }

    /// 当前环境光代理读数（0…1）。nil = 暂时拿不到（降级，由调用方处理）。
    static func normalizedLevel() -> Double? {
        guard let builtin = onlineBuiltinID() else { return nil }
        // 首选线性亮度（ALC 的真实输出，均匀可映射）；
        // 线性接口拿不到就退回用户亮度（0…1），口径略糙但方向一致。
        if let lin = linearBrightness(of: builtin), let range = usableRange(of: builtin) {
            return min(1, max(0, (lin - range.min) / (range.max - range.min)))
        }
        guard let fn = PrivateAPI.shared.getBrightness,
              PrivateAPI.shared.canChangeBrightness?(builtin) != 0 else { return nil }
        var v: Float = -1
        guard fn(builtin, &v) == 0, v >= 0 else { return nil }
        return Double(v)
    }
}
