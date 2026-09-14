// 检查页面里 WebGL 流光背景的真实效果，两种输出：
//
//   1. 默认：把画布自己的像素导出成 PNG（看着色器本身长什么样）
//   2. --compose：把画布像素贴回页面当背景层，再截整屏（看它和文字/卡片叠在一起的样子）
//
// 为什么要绕这一圈：WKWebView 的 takeSnapshot 抓不到 WebGL 合成层，直接截图那块是黑的；
// 而离屏窗口不参与合成，也就不会产生 rAF 帧，着色器根本不会跑。
// 所以流程是「用 setTimeout 手动驱动几帧 → 把像素搬进普通 DOM 背景 → 再截图」。
//
// 用法：
//   swift fxshot.swift <url> <out.png> [宽 高] [等待秒数] [dark|light] [--compose]
//   swift fxshot.swift file:///path/docs/index.html /tmp/fx.png 1280 860 1.5 dark --compose

import AppKit
import WebKit

final class FxShot: NSObject, WKNavigationDelegate {

    private let url: URL
    private let outPath: String
    private let size: CGSize
    private let wait: Double
    private let theme: String
    private let compose: Bool
    private var webView: WKWebView!
    private var window: NSWindow!
    private var done = false

    init(url: URL, outPath: String, width: CGFloat, height: CGFloat,
         wait: Double, theme: String, compose: Bool) {
        self.url = url
        self.outPath = outPath
        self.size = CGSize(width: width, height: height)
        self.wait = wait
        self.theme = theme
        self.compose = compose
        super.init()
    }

    func start() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        if theme == "light" || theme == "dark" {
            let js = "try{localStorage.setItem('dm-theme','\(theme)')}catch(e){}"
            config.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)

        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.drive() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("加载失败: \(error.localizedDescription)")
        exit(1)
    }

    /// 离屏窗口不会被合成，也就不会产生 rAF 帧。用 setTimeout 手动驱动一批帧
    /// （setTimeout 不受合成影响），顺便把光标定在标题附近，让交互效果也出现在画面里。
    private func drive() {
        let js = """
        (function () {
          var fx = window.DisplayMasterFx;
          if (!fx || !fx.render) return 'no-hook';
          var frames = 50;
          for (var i = 0; i < frames; i++) {
            (function (i) {
              setTimeout(function () {
                fx.setPointer(0.36, 0.68);
                fx.render(5.0 + i * 0.02);
              }, i * 8);
            })(i);
          }
          return 'driving ' + frames;
        })()
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("驱动渲染失败: \(error.localizedDescription)")
            } else if let text = result as? String {
                print("驱动: \(text)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if self.compose { self.composeBackground() } else { self.grab() }
            }
        }
    }

    /// 把画布像素变成普通 DOM 的背景图（blob URL，不用把几 MB 数据传回宿主），
    /// 这样后续截图就能拿到背景 —— 顺带也验证了画布内容确实画出来了。
    private func composeBackground() {
        let js = """
        (function () {
          var c = document.querySelector('canvas.fx');
          if (!c) return 'no-canvas';
          if (window.DisplayMasterFx && window.DisplayMasterFx.pause) window.DisplayMasterFx.pause();
          c.toBlob(function (blob) {
            var url = URL.createObjectURL(blob);
            var d = document.createElement('div');
            d.id = '__fxbg';
            d.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;' +
                              'z-index:-1;pointer-events:none;background-size:cover;background-position:center;';
            d.style.backgroundImage = 'url(' + url + ')';
            document.body.appendChild(d);
            c.style.visibility = 'hidden';
            window.__fxComposed = 'ok';
          }, 'image/png');
          return 'composing';
        })()
        """
        webView.evaluateJavaScript(js) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.snapshot() }
        }
    }

    private func snapshot() {
        guard !done else { return }
        done = true

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("截图失败: \(String(describing: error))")
                NSApp.terminate(nil)
                return
            }
            try? png.write(to: URL(fileURLWithPath: self.outPath))
            print("已保存 \(self.outPath) (\(Int(image.size.width))×\(Int(image.size.height)))")
            NSApp.terminate(nil)
        }
    }

    private func grab() {
        guard !done else { return }
        done = true

        let js = """
        (function () {
          try {
            var c = document.querySelector('canvas.fx');
            if (!c) return 'ERR|no-canvas';
            if (window.DisplayMasterFx && window.DisplayMasterFx.pause) window.DisplayMasterFx.pause();
            var gl = c.getContext('webgl') || c.getContext('experimental-webgl');
            var diag = {
              css: window.innerWidth + 'x' + window.innerHeight,
              buf: c.width + 'x' + c.height,
              hasGL: !!gl,
              fxOff: document.documentElement.classList.contains('fx-off'),
              hook: !!window.DisplayMasterFx,
              themeAttr: document.documentElement.getAttribute('data-theme'),
              renderer: ''
            };
            if (gl) {
              var ext = gl.getExtension('WEBGL_debug_renderer_info');
              if (ext) diag.renderer = String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL));
            }
            return 'OK|' + JSON.stringify(diag) + '|' + c.toDataURL('image/png');
          } catch (e) {
            return 'ERR|' + e;
          }
        })()
        """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("取画布失败: \(error.localizedDescription)")
                exit(1)
            }
            guard let text = result as? String else {
                print("返回值不是字符串")
                exit(1)
            }

            let parts = text.components(separatedBy: "|")
            guard parts.count >= 2, parts[0] == "OK" else {
                print("页面诊断: \(text.prefix(400))")
                exit(1)
            }
            print("页面诊断: \(parts[1])")

            guard parts.count >= 3, let comma = parts[2].range(of: "base64,") else {
                print("没有拿到 dataURL")
                exit(1)
            }
            let b64 = String(parts[2][comma.upperBound...])
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                print("base64 解码失败，长度 \(b64.count)")
                exit(1)
            }
            do {
                try data.write(to: URL(fileURLWithPath: self.outPath))
                print("已保存 \(self.outPath) (\(data.count) 字节)")
            } catch {
                print("写入失败: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}

var args: [String] = []
var width = 1280.0
var height = 860.0
var wait = 1.5
var theme = "dark"
var compose = false

let argv = CommandLine.arguments
guard argv.count >= 3, let target = URL(string: argv[1]) else {
    print("用法: swift fxshot.swift <url> <out.png> [宽 高] [等待秒数] [dark|light] [--compose]")
    exit(1)
}

let outPath = argv[2]
for arg in argv.dropFirst(3) {
    if arg == "--compose" { compose = true }
    else if arg == "dark" || arg == "light" { theme = arg }
    else if let v = Double(arg) {
        if args.isEmpty { width = v } else if args.count == 1 { height = v } else { wait = v }
        args.append(arg)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let shot = FxShot(url: target, outPath: outPath,
                  width: CGFloat(width), height: CGFloat(height),
                  wait: wait, theme: theme, compose: compose)
shot.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
    print("超时退出")
    exit(2)
}

app.run()
