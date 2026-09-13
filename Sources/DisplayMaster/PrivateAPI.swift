import Foundation
import CoreGraphics
import Darwin

/// 统一管理 Apple 私有符号（运行时 dlsym 加载，不链接私有框架、无需 entitlement）
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
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let displaySvc = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        let global = dlopen(nil, RTLD_LAZY)

        configureDisplayEnabled = PrivateAPI.load([skyLight, global], "CGSConfigureDisplayEnabled", ConfigureDisplayEnabledF.self)
        getBrightness = PrivateAPI.load([displaySvc, global], "DisplayServicesGetBrightness", GetBrightnessF.self)
        setBrightness = PrivateAPI.load([displaySvc, global], "DisplayServicesSetBrightness", SetBrightnessF.self)
        canChangeBrightness = PrivateAPI.load([displaySvc, global], "DisplayServicesCanChangeBrightness", CanChangeBrightnessF.self)
    }

    private static func load<T>(_ handles: [UnsafeMutableRawPointer?], _ name: String, _ type: T.Type) -> T? {
        for h in handles {
            guard let h = h, let sym = dlsym(h, name) else { continue }
            return unsafeBitCast(sym, to: T.self)
        }
        return nil
    }
}
