import Foundation
import Network
import OSLog

private let serverLog = Logger(subsystem: "com.flowtrack", category: "BlockPageServer")

// MARK: - BlockPageServer
/// Lightweight HTTP server on port 8080 that serves the custom block page.
/// pfctl redirects 127.0.0.1:80 → 127.0.0.1:8080 (set up by AppBlockerStore via osascript).
@MainActor @Observable
final class BlockPageServer {
    static let shared = BlockPageServer()
    static let serverPort: UInt16 = 8080

    private(set) var isRunning = false
    private var listener: NWListener?

    private init() {}

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: Self.serverPort)!
        guard let l = try? NWListener(using: params, on: port) else {
            serverLog.error("Failed to create listener on port \(Self.serverPort)")
            return
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    serverLog.info("Block page server listening on port \(BlockPageServer.serverPort)")
                case .failed(let err):
                    serverLog.error("Block page server failed: \(err.localizedDescription)")
                    self?.isRunning = false
                default: break
                }
            }
        }
        l.newConnectionHandler = { conn in
            Self.handle(connection: conn)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    nonisolated private static func handle(connection conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let host = extractHost(from: data)
            let html = blockPageHTML(for: host)
            let utf8 = html.data(using: .utf8) ?? Data()
            let response = "HTTP/1.1 200 OK\r\n" +
                           "Content-Type: text/html; charset=utf-8\r\n" +
                           "Content-Length: \(utf8.count)\r\n" +
                           "Cache-Control: no-store\r\n" +
                           "Connection: close\r\n\r\n"
            var payload = response.data(using: .utf8)!
            payload.append(utf8)
            conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    nonisolated private static func extractHost(from data: Data?) -> String {
        guard let data, let req = String(data: data, encoding: .utf8) else { return "" }
        for line in req.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return raw.components(separatedBy: ":").first ?? raw
            }
        }
        return ""
    }

    // MARK: - Block page HTML

    static func blockPageHTML(for host: String) -> String {
        let domain = host.isEmpty ? "this site" : host
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Blocked — FlowTrack</title>
        <style>
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          :root { color-scheme: dark; }
          body {
            min-height: 100vh;
            background: radial-gradient(ellipse at 30% 20%, #1e1333 0%, #0d0d1a 60%, #0a0a14 100%);
            display: flex; align-items: center; justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', sans-serif;
            color: #e2e2f0; overflow: hidden;
          }
          .bg-orb {
            position: fixed; border-radius: 50%; filter: blur(80px); opacity: 0.12; pointer-events: none;
          }
          .bg-orb-1 { width: 500px; height: 500px; background: #7c3aed; top: -100px; left: -100px; }
          .bg-orb-2 { width: 400px; height: 400px; background: #2563eb; bottom: -80px; right: -80px; }
          .card {
            position: relative; text-align: center;
            padding: 56px 52px 48px;
            max-width: 480px; width: calc(100% - 40px);
            background: rgba(255,255,255,0.04);
            border: 1px solid rgba(255,255,255,0.09);
            border-radius: 28px;
            backdrop-filter: blur(24px);
            -webkit-backdrop-filter: blur(24px);
            box-shadow: 0 32px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.04) inset;
            animation: appear 0.4s cubic-bezier(0.34, 1.56, 0.64, 1) both;
          }
          @keyframes appear {
            from { opacity: 0; transform: scale(0.88) translateY(16px); }
            to   { opacity: 1; transform: scale(1)    translateY(0); }
          }
          .shield-wrap {
            width: 88px; height: 88px; margin: 0 auto 28px;
            background: linear-gradient(135deg, #7c3aed 0%, #4f46e5 100%);
            border-radius: 24px;
            display: flex; align-items: center; justify-content: center;
            box-shadow: 0 12px 36px rgba(124,58,237,0.4);
            font-size: 40px;
          }
          .badge {
            display: inline-flex; align-items: center; gap: 6px;
            font-size: 11px; font-weight: 700; letter-spacing: 2.5px;
            text-transform: uppercase; color: #a78bfa;
            background: rgba(167,139,250,0.1);
            border: 1px solid rgba(167,139,250,0.2);
            padding: 5px 12px; border-radius: 20px; margin-bottom: 18px;
          }
          h1 {
            font-size: 30px; font-weight: 800; line-height: 1.1;
            background: linear-gradient(135deg, #fff 30%, #c4b5fd 100%);
            -webkit-background-clip: text; -webkit-text-fill-color: transparent;
            background-clip: text; margin-bottom: 10px;
          }
          .domain-pill {
            display: inline-block;
            font-size: 13px; font-family: 'SF Mono', 'Fira Code', monospace;
            color: rgba(255,255,255,0.45);
            background: rgba(255,255,255,0.05);
            border: 1px solid rgba(255,255,255,0.08);
            padding: 5px 14px; border-radius: 20px; margin-bottom: 22px;
          }
          .message {
            font-size: 15px; color: rgba(255,255,255,0.65); line-height: 1.65;
            margin-bottom: 36px;
          }
          .divider {
            height: 1px; background: rgba(255,255,255,0.07); margin-bottom: 24px;
          }
          .quote {
            font-size: 13px; color: rgba(255,255,255,0.35);
            font-style: italic; line-height: 1.5;
          }
          .quote cite { display: block; margin-top: 6px; font-style: normal; font-weight: 600; color: rgba(255,255,255,0.2); font-size: 11px; }
        </style>
        </head>
        <body>
          <div class="bg-orb bg-orb-1"></div>
          <div class="bg-orb bg-orb-2"></div>
          <div class="card">
            <div class="shield-wrap">🛡️</div>
            <div class="badge">🌊 FlowTrack</div>
            <h1>Site Blocked</h1>
            <div class="domain-pill">\(domain)</div>
            <p class="message">
              You added this site to your block list to help you<br>
              stay focused and make the most of your time.
            </p>
            <div class="divider"></div>
            <p class="quote">
              "The secret of getting ahead is getting started."
              <cite>— Mark Twain</cite>
            </p>
          </div>
        </body>
        </html>
        """
    }
}
