import AppKit
import CoreGraphics

/// 自绘面板的尺寸与配色。
///
/// 集中放一处是有原因的：菜单里原生项和自绘项会并排出现，
/// 面板宽度、左右留白这些数字必须一起调，否则两边的文字列对不齐。
enum PanelStyle {

    // MARK: 卡片行

    /// 单张卡片的宽度。**卡片是横着排的**：几台显示器就并排几张卡，
    /// 每张卡自带亮度、分辨率两条滑块，加开启、HiDPI 两枚开关 ——
    /// 关掉的屏也占一张卡，只是「开启」是关着的，
    /// 而不是被挪到菜单底下去单独列一行。
    static let cardWidth: CGFloat = 200
    /// 一页最多几张卡
    static let maxCardsPerPage = 4
    /// 需要翻页时一页放几张。4 张再加两侧箭头，菜单会宽到 890pt —— 宁可少放一张
    static let maxCardsPerPagePaged = 3
    /// 面板最小宽度。只有一台屏时卡片会被拉宽到这个宽度，底部那些行才不至于比卡片还宽
    static let minWidth: CGFloat = 340
    static let margin: CGFloat = 16
    static let gap: CGFloat = 12
    static let arrowWidth: CGFloat = 18
    /// 上边距。菜单项视图是顶着菜单窗口上沿放的，不留白第一行文字会被圆角切掉
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 10

    // MARK: 卡片内部（自上而下，改一个要连着看下一个）

    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardTopInset: CGFloat = 12
    static let thumbHeight: CGFloat = 52
    static let thumbGap: CGFloat = 10
    static let titleHeight: CGFloat = 18
    static let modelHeight: CGFloat = 15
    static let specHeight: CGFloat = 15
    /// 分辨率行与分隔线之间
    static let sectionGap: CGFloat = 10
    /// 分隔线与第一条控制行之间
    static let afterDividerGap: CGFloat = 11

    // 两条控制行：亮度、分辨率。**两行必须长得一样**，这是刻意的：
    //   标签行：图标 + 名称 ……（靠右）当前值
    //   滑块行：整条轨道
    // 两行的标签、轨道都从同一个 x 起、到同一个 x 止，看着才是「对齐的」。
    // 也正因为如此，数值从「轨道右边那一小格」挪到了「上一行的右端」——
    // 留在轨道右边的话，分辨率的「1680 × 1050」比「95%」宽一倍多，
    // 两条轨道就会一长一短，反而对不齐了。
    static let controlLabelHeight: CGFloat = 16
    static let controlSliderHeight: CGFloat = 20
    /// 两条控制行之间
    static let controlRowGap: CGFloat = 8
    static let cardBottomInset: CGFloat = 11

    /// 亮度百分比那一列的宽度。两条控制行的数值都右对齐到这同一列里
    static let percentWidth: CGFloat = 38
    /// 「1680 × 1050」这种分辨率文字占的宽度
    static let resValueWidth: CGFloat = 78
    /// 分辨率数值左边那枚「HiDPI」小字
    static let hidpiMarkWidth: CGFloat = 32

    /// 轨道与圆头。设计图上是一条很细的常规轨道（不是手稿那种粗胶囊），
    /// 5pt 是「看得出是条轨道、又不至于像 iOS 那样厚重」的折中。
    static let trackHeight: CGFloat = 5
    static let knobDiameter: CGFloat = 13
    /// 分辨率滑块每一档在轨道上点一颗小圆点：档位是离散的，
    /// 不点出来会被当成连续量 —— 拖一半到两个档位中间，松手却跳到其中一档，很困惑
    static let tickDiameter: CGFloat = 3

    /// 开关尺寸。按设计图的比例（开关高 ≈ 卡片宽的 0.09）取 18
    static let switchWidth: CGFloat = 30
    static let switchHeight: CGFloat = 18
    /// 右上角那一簇开关的行高、行距。两枚开关上下摞，正好落在缩略图那一行里
    static let switchRowHeight: CGFloat = 20
    static let switchRowGap: CGFloat = 6
    /// 开关与它左边那行小字的间距
    static let switchLabelGap: CGFloat = 7
    static let switchLabelFont: NSFont = .systemFont(ofSize: 10.5)
    /// 开关簇的宽度：由最宽的那一行（「HiDPI」+ 开关）决定。
    /// 整簇贴着卡片右上角放，缩略图就画在它左边剩下的地方。
    static var switchClusterWidth: CGFloat {
        panelTextWidth("HiDPI", font: switchLabelFont) + switchLabelGap + switchWidth
    }

    static var cardFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var hoverFill: NSColor { NSColor.labelColor.withAlphaComponent(0.11) }
    static var hairline: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.16) }
    /// 开关/徽章这类小控件悬停时的浅底
    static var controlHover: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }

    /// 卡片高度：把上面那一串内部尺寸加起来，别再手写一个魔数
    static var cardHeight: CGFloat {
        cardTopInset + thumbHeight + thumbGap
            + titleHeight + modelHeight + specHeight
            + sectionGap + 1 + afterDividerGap
            + (controlLabelHeight + controlSliderHeight) * 2 + controlRowGap
            + cardBottomInset
    }

    /// 一页放几张：超过 4 台才翻页，翻页时一页只放 3 张
    static func perPage(count: Int) -> Int {
        count > maxCardsPerPage ? maxCardsPerPagePaged : maxCardsPerPage
    }

    static func pageCount(count: Int) -> Int {
        max(1, Int(ceil(Double(count) / Double(perPage(count: count)))))
    }

    /// 整个面板（= 卡片行）的宽度。
    /// 注意用**一页放几张**去算，不是显示器总数 —— 6 台屏是一页 3 张分两页，
    /// 按 6 张算宽度会得到 1300pt 那么离谱的菜单。
    static func panelWidth(count: Int) -> CGFloat {
        let n = CGFloat(min(max(count, 1), perPage(count: count)))
        let arrows = pageCount(count: count) > 1 ? arrowWidth * 2 : 0
        let natural = margin * 2 + n * cardWidth + (n - 1) * gap + arrows
        return max(natural, minWidth + arrows)
    }

    /// 每张卡在面板里实际拿到的宽度
    static func columnWidth(panelWidth w: CGFloat, count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let arrows = pageCount(count: count) > 1 ? arrowWidth * 2 : 0
        return (w - margin * 2 - arrows - (n - 1) * gap) / n
    }

    static func rowHeight(cardCount: Int) -> CGFloat { topInset + cardHeight + bottomInset }
}
