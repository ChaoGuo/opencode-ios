import Foundation

// SSE events are plain `data: {JSON}\n\n` — no `event:` line.
// JSON structure: { "type": "session.created", "properties": {...} }

final class SSEService: NSObject {
    static let shared = SSEService()

    // Callback receives the raw SSE envelope JSON data
    var onEnvelope: ((Data) -> Void)?
    var onConnected: ((Bool) -> Void)?

    private var dataTask: URLSessionDataTask?
    private var urlSession: URLSession?
    private var buffer = ""
    private var reconnectWorkItem: DispatchWorkItem?

    private override init() { super.init() }

    func connect() {
        guard let req = try? APIService.shared.makeSSERequest() else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        dataTask = session.dataTask(with: req)
        dataTask?.resume()
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        buffer = ""
        DispatchQueue.main.async { self.onConnected?(false) }
    }

    private func scheduleReconnect() {
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // Parse `data: {JSON}\n\n` blocks
    private func process(_ chunk: String) {
        buffer += chunk
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("data:") {
                    let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let data = json.data(using: .utf8) {
                        DispatchQueue.main.async { self.onEnvelope?(data) }
                    }
                }
            }
        }
    }
}

extension SSEService: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            DispatchQueue.main.async { self.onConnected?(true) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async { self.process(text) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { self.onConnected?(false) }
        if error != nil { scheduleReconnect() }
    }
}
