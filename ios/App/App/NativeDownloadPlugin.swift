import Foundation
import UIKit
import WebKit
import Capacitor

/// Одно скачивание: хранит вызов из JS и состояние.
fileprivate final class DownloadJob {
    let call: CAPPluginCall
    let hint: String
    var answered = false      // JS уже получил ответ (resolve/reject)
    var checked = false       // заголовки ответа сервера проверены
    var bad = false           // сервер вернул не файл
    var code = 0
    var name = ""
    var failMessage: String?
    var saved: URL?

    init(call: CAPPluginCall, hint: String) {
        self.call = call
        self.hint = hint
    }
}

/// Скачивание файлов и ZIP с cloud.shpionbot.ru (аналог Android-плагина NativeDownloadPlugin).
/// Делает ОДИН запрос к серверу (важно для ссылок с лимитом скачиваний), cookie сессии берёт из WKWebView,
/// умеет GET и POST (форма «скачать выбранное»), имя файла берёт из Content-Disposition.
/// Файл сохраняется в Documents приложения (виден в «Файлы» → «На iPhone» → ShpionBot Cloud),
/// после скачивания открывается меню «Поделиться».
@objc(NativeDownloadPlugin)
public class NativeDownloadPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeDownloadPlugin"
    public let jsName = "NativeDownload"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "download", returnType: CAPPluginReturnPromise)
    ]

    /// Плагин ходит только на этот адрес — чужие URL отклоняются.
    static let baseHost = "cloud.shpionbot.ru"
    static let base = "https://cloud.shpionbot.ru/"

    fileprivate var jobs: [Int: DownloadJob] = [:]   // taskIdentifier -> скачивание
    fileprivate let lock = NSLock()
    private var pending = 0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - вызов из JS

    @objc func download(_ call: CAPPluginCall) {
        let urlStr = call.getString("url") ?? ""
        guard urlStr.hasPrefix(NativeDownloadPlugin.base), let url = URL(string: urlStr) else {
            call.reject("Недопустимый адрес")
            return
        }
        let post = (call.getString("method") ?? "GET").uppercased() == "POST"
        let body = call.getString("body") ?? ""
        let hint = call.getString("filename") ?? ""
        let ticket = call.getString("ticket") ?? ""

        bridge?.saveCall(call)

        DispatchQueue.main.async {
            guard let store = self.bridge?.webView?.configuration.websiteDataStore.httpCookieStore else {
                self.start(call: call, url: url, post: post, body: body, hint: hint, ticket: ticket, cookie: "")
                return
            }
            store.getAllCookies { cookies in
                let host = NativeDownloadPlugin.baseHost
                let mine = cookies.filter { c in
                    let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return host == d || host.hasSuffix("." + d)
                }
                let cookie = HTTPCookie.requestHeaderFields(with: mine)["Cookie"] ?? ""
                self.start(call: call, url: url, post: post, body: body, hint: hint, ticket: ticket, cookie: cookie)
            }
        }
    }

    private func start(call: CAPPluginCall, url: URL, post: Bool, body: String, hint: String, ticket: String, cookie: String) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        // «билет» от страницы: надёжный вход без cookie (для файлов из личных папок)
        if !ticket.isEmpty { req.setValue(ticket, forHTTPHeaderField: "X-Dl-Ticket") }
        if post {
            req.httpMethod = "POST"
            req.httpBody = body.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let task = session.downloadTask(with: req)
        let job = DownloadJob(call: call, hint: hint)
        lock.lock()
        jobs[task.taskIdentifier] = job
        lock.unlock()
        busy(1)
        task.resume()
    }

    // MARK: - экран не гаснет, пока идёт скачивание

    private func busy(_ delta: Int) {
        DispatchQueue.main.async {
            self.pending = max(0, self.pending + delta)
            UIApplication.shared.isIdleTimerDisabled = self.pending > 0
            if self.pending > 0, self.bgTask == .invalid {
                self.bgTask = UIApplication.shared.beginBackgroundTask(withName: "shpion-download") { [weak self] in
                    guard let self = self else { return }
                    UIApplication.shared.endBackgroundTask(self.bgTask)
                    self.bgTask = .invalid
                }
            } else if self.pending == 0, self.bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTask)
                self.bgTask = .invalid
            }
        }
    }

    // MARK: - проверка ответа сервера

    fileprivate func jobFor(_ task: URLSessionTask) -> DownloadJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    /// Проверяем заголовки один раз; если это файл — отвечаем JS (скачивание продолжается в фоне).
    fileprivate func validate(_ job: DownloadJob, task: URLSessionTask) {
        if job.checked { return }
        job.checked = true
        guard let http = task.response as? HTTPURLResponse else {
            job.bad = true
            return
        }
        job.code = http.statusCode
        let cd = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if http.statusCode != 200 || !cd.lowercased().contains("attachment") {
            job.bad = true
            return
        }
        job.name = NativeDownloadPlugin.safeName(NativeDownloadPlugin.parseFileName(cd), job.hint)
        job.answered = true
        job.call.resolve(["name": job.name])
        bridge?.releaseCall(job.call)
    }

    fileprivate func fail(_ job: DownloadJob, _ msg: String) {
        if !job.answered {
            job.answered = true
            job.call.reject(msg)
            bridge?.releaseCall(job.call)
        } else {
            notifyListeners("done", data: ["ok": false, "name": job.name, "error": msg])
            alert("Не удалось скачать" + (job.name.isEmpty ? "" : ": " + job.name), msg)
        }
    }

    // MARK: - интерфейс

    private func topController() -> UIViewController? {
        var top = self.bridge?.viewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    private func alert(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            guard let vc = self.topController() else { return }
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            vc.present(a, animated: true)
        }
    }

    fileprivate func presentShare(_ file: URL) {
        DispatchQueue.main.async {
            guard let vc = self.topController() else { return }
            let av = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let pop = av.popoverPresentationController {
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            vc.present(av, animated: true)
        }
    }

    // MARK: - вспомогательное

    fileprivate static func parseFileName(_ cd: String) -> String {
        let ns = cd as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let re = try? NSRegularExpression(pattern: "filename\\*\\s*=\\s*[^']*'[^']*'([^;]+)", options: [.caseInsensitive]),
           let m = re.firstMatch(in: cd, options: [], range: full), m.numberOfRanges > 1 {
            let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let d = raw.removingPercentEncoding { return d }
        }
        if let re = try? NSRegularExpression(pattern: "filename\\s*=\\s*\"?([^\";]+)\"?", options: [.caseInsensitive]),
           let m = re.firstMatch(in: cd, options: [], range: full), m.numberOfRanges > 1 {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    fileprivate static func safeName(_ fromHeader: String, _ hint: String) -> String {
        var s = fromHeader.isEmpty ? hint : fromHeader
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let chars: [Character] = s.unicodeScalars.map { bad.contains($0) ? Character("_") : Character($0) }
        s = String(chars).trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "download" }
        // файловая система: не больше 255 байт; расширение сохраняем
        var ext = (s as NSString).pathExtension
        if ext.count > 10 { ext = "" }
        let dotExt = ext.isEmpty ? "" : "." + ext
        var base = ext.isEmpty ? s : String(s.dropLast(dotExt.count))
        if base.isEmpty { base = "download" }
        while (base + dotExt).utf8.count > 240 && base.count > 1 { base.removeLast() }
        return base + dotExt
    }

    fileprivate func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var i = 1
        while true {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let u = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }

    fileprivate func errorText(_ code: Int, body: URL?) -> String {
        if code == 401 { return "Сессия истекла — войдите заново" }
        if let b = body, let data = try? Data(contentsOf: b, options: .mappedIfSafe) {
            let head = Data(data.prefix(4096))
            if let obj = (try? JSONSerialization.jsonObject(with: head)) as? [String: Any],
               let e = obj["error"] as? String, !e.isEmpty {
                return e
            }
        }
        switch code {
        case 403: return "Нет доступа — войдите заново"
        case 404: return "Файл не найден"
        case 410: return "Ссылка больше не действует"
        case 200: return "Ссылка недоступна: истёк срок, исчерпан лимит или нужно войти заново"
        default: return "Ошибка сервера (\(code))"
        }
    }
}

// MARK: - делегат URLSession

extension NativeDownloadPlugin: URLSessionDownloadDelegate {

    /// Редиректы только на тот же сайт по https (чужим серверам cookie и билет не отдаём).
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme == "https", request.url?.host == NativeDownloadPlugin.baseHost {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let job = jobFor(downloadTask) else { return }
        validate(job, task: downloadTask)
        // вместо файла пришла большая страница — не качаем её целиком
        if job.bad && totalBytesWritten > 1_048_576 && job.failMessage == nil {
            job.failMessage = errorText(job.code, body: nil)
            downloadTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let job = jobFor(downloadTask) else { return }
        validate(job, task: downloadTask)
        if job.bad {
            job.failMessage = errorText(job.code, body: location)
            return
        }
        // файл надо переместить до выхода из этого метода — иначе система его удалит
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = uniqueURL(docs.appendingPathComponent(job.name))
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            job.saved = dest
        } catch {
            job.failMessage = "Не удалось сохранить файл: " + error.localizedDescription
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let found = jobs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let job = found else { return }
        busy(-1)

        if let err = error {
            let ns = err as NSError
            let msg = job.failMessage ?? (ns.code == NSURLErrorCancelled ? "Скачивание отменено" : ns.localizedDescription)
            fail(job, msg)
            return
        }
        if let msg = job.failMessage {
            fail(job, msg)
            return
        }
        if let file = job.saved {
            notifyListeners("done", data: ["ok": true, "name": file.lastPathComponent])
            presentShare(file)
        }
    }
}
