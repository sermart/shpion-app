import UIKit
import Capacitor

/// Главный экран. Нужен, чтобы зарегистрировать свой плагин NativeDownload
/// (в Capacitor 6+ плагины, лежащие прямо в проекте приложения, регистрируются здесь).
@objc(MainViewController)
class MainViewController: CAPBridgeViewController {

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativeDownloadPlugin())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // сайт тёмный: тёмный стиль даёт светлый текст в строке состояния и тёмную клавиатуру
        overrideUserInterfaceStyle = .dark
        let bg = UIColor(red: 5.0 / 255, green: 5.0 / 255, blue: 5.0 / 255, alpha: 1)
        view.backgroundColor = bg
        webView?.isOpaque = false
        webView?.backgroundColor = bg
        webView?.scrollView.backgroundColor = bg
    }
}
