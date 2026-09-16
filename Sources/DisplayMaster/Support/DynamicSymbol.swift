import Darwin

/// 统一管理 Apple 私有符号的运行时加载。
///
/// 私有 API 一律走 `dlopen` / `dlsym`：不链接私有框架、不需要 entitlement，
/// 符号不存在时只是拿到 nil（`--selftest` 会把它打出来），而不是启动即崩。
///
/// 两个用到私有 API 的封装类（`PrivateAPI` 的显示配置与内置屏亮度、`DDC` 的
/// IOAVService）共用这一份实现 —— 原先「按顺序在几个句柄里找符号」这段循环
/// 各写了一遍，改一处漏一处的风险没有必要留着。
enum DynamicSymbol {

    /// `dlopen` 一个框架路径；传 nil 表示全局符号表（`dlopen(nil)`）。
    ///
    /// 打不开就返回 nil，`load` 会把它跳过 —— 缺一个框架不该让整个进程起不来。
    static func open(_ path: String?) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_LAZY)
    }

    /// 按给定顺序在若干句柄里查找符号，**第一个找到的胜出**。
    ///
    /// - Parameters:
    ///   - name: C 符号名。
    ///   - handles: `open` 得到的句柄，顺序即查找顺序（专有框架在前，全局符号表兜底）。
    ///   - type: 该符号的函数类型。
    static func load<T>(_ name: String,
                        from handles: [UnsafeMutableRawPointer?],
                        as type: T.Type) -> T? {
        for handle in handles {
            guard let handle = handle, let symbol = dlsym(handle, name) else { continue }
            return unsafeBitCast(symbol, to: T.self)
        }
        return nil
    }
}
