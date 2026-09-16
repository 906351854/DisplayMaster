import Foundation
import CoreGraphics

/// 统一管理「显示配置 + 内置屏亮度」这几个 Apple 私有符号。
/// 加载走 `DynamicSymbol`（运行时 dlsym，不链接私有框架、无需 entitlement）。
final class PrivateAPI {
    static let shared = PrivateAPI()

    typealias ConfigureDisplayEnabledF = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
    typealias GetBrightnessF = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessF = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightnessF = @convention(c) (CGDirectDisplayID) -> Int32

    let configureDisplayEnabled: ConfigureDisplayEnabledF?
    let getBrightness: GetBrightnessF?
    let setBrightness: SetBrightnessF?
    let canChangeBrightness: CanChangeBrightnessF?

    private init() {
        // 保持原来的打开顺序：专有框架在前，全局符号表兜底（见 DynamicSymbol.load）
        let skyLight = DynamicSymbol.open("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
        let displaySvc = DynamicSymbol.open("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
        let global = DynamicSymbol.open(nil)

        configureDisplayEnabled = DynamicSymbol.load("CGSConfigureDisplayEnabled",
                                                     from: [skyLight, global],
                                                     as: ConfigureDisplayEnabledF.self)
        getBrightness = DynamicSymbol.load("DisplayServicesGetBrightness",
                                          from: [displaySvc, global],
                                          as: GetBrightnessF.self)
        setBrightness = DynamicSymbol.load("DisplayServicesSetBrightness",
                                          from: [displaySvc, global],
                                          as: SetBrightnessF.self)
        canChangeBrightness = DynamicSymbol.load("DisplayServicesCanChangeBrightness",
                                                from: [displaySvc, global],
                                                as: CanChangeBrightnessF.self)
    }
}
