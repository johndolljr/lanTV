import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
let url = URL(string: "http://source.lan:8000/guide.xml")!
func channel(_ source: String, _ raw: String) -> GuideChannel {
    GuideChannel(id: "\(source)::\(raw)", sourceID: source, rawChannelID: raw, name: "Secret \(source)", number: nil, detail: nil, keyword: nil, logoURL: nil, streamURL: URL(string: "http://source.lan:8000/video?channel=\(raw)")!, xmltvURL: url, programmes: [])
}
var settings = AppSettings.default
settings.sources = [GuideSource(id: "one", kind: .xmltv(url: url, streamURLTemplate: "http://source.lan/video?channel={channel}"))]
settings.adultChannelIDsBySource = ["one": ["1"]]
let items = [channel("one", "1"), channel("two", "1")]
func context(_ unlocked: Bool) -> LocalAPIExportContext {
    .init(baseURLs: [], visibleChannels: items, generatedAt: Date(timeIntervalSince1970: 1), sourceStatus: ["one": "Failed loading http://private-source.lan/secret-guide.xml"], settings: settings, areProtectedChannelsUnlocked: unlocked, selectedChannelID: "one::1", isPlayerDetached: false)
}
func string(_ payloads: [String: LocalAPIServer.HTTPPayload], _ path: String) -> String {
    String(data: payloads[path]!.data, encoding: .utf8)!
}
let locked = LocalAPIExportRenderer.render(context: context(false))
let open = LocalAPIExportRenderer.render(context: context(true))
check(!string(locked, "/api/guide.xmltv").contains("one::1"), "locked channel omitted even if context contains it")
check(string(open, "/api/guide.xmltv").contains("id=\"one::1\""), "globally unique channel IDs")
check(string(open, "/api/guide.xmltv").contains("id=\"two::1\""), "same raw channel IDs do not collide")
check(string(open, "/api/guide.xmltv").contains("<stream-url>http://source.lan:8000/video?channel=1</stream-url>"), "direct upstream stream URL")
check(!string(locked, "/api/settings.json").contains("source.lan"), "locked settings do not leak upstream URL template")
check(!string(locked, "/api/state.json").contains("one::1"), "locked selection redacted")
check(!string(locked, "/api/state.json").contains("private-source.lan"), "locked source errors do not leak upstream guide addresses")
check(string(open, "/api/state.json").contains("private-source.lan"), "unlocked source diagnostics remain available")
let lockedState = try JSONSerialization.jsonObject(with: locked["/api/mobile/state.json"]!.data) as! [String: Any]
let openState = try JSONSerialization.jsonObject(with: open["/api/mobile/state.json"]!.data) as! [String: Any]
check(lockedState["revision"] as? String != openState["revision"] as? String, "lock changes revision")
check(string(locked, "/api/guide.xmltv").contains("lanTV-revision=\"\(lockedState["revision"]!)\""), "guide and state revision agree")
let router = LocalAPIRequestRouter()
router.payloads = locked
var requests: [MobileUnlockRequest] = []
router.onUnlockRequest = { requests.append($0) }
let id = UUID().uuidString
let request = "POST /api/mobile/unlock-request?deviceID=\(id)&deviceName=Test%20iPhone HTTP/1.1\r\nHost: desktop.lan\r\n\r\n"
check(router.route(requestText: request).statusCode == 202, "request queues")
check(requests.count == 1, "desktop callback notified")
check(router.route(requestText: request).statusCode == 202 && requests.count == 1, "duplicates coalesce")
check(router.route(requestText: "GET /api/mobile/unlock-request HTTP/1.1\r\n\r\n").statusCode == 405, "GET cannot request unlock")
check(router.route(requestText: "POST /api/mobile/approve HTTP/1.1\r\n\r\n").statusCode == 405, "no remote approval route")
check(router.route(requestText: "POST /api/mobile/unlock-request?deviceID=no&deviceName=x HTTP/1.1\r\n\r\n").statusCode == 400, "bad client UUID rejected")
check(router.route(requestText: "GET /unknown HTTP/1.1\r\n\r\n").statusCode == 404, "missing endpoint 404")
check(router.route(requestText: "DELETE /api/state.json HTTP/1.1\r\n\r\n").statusCode == 405, "method rejected")
check(router.route(requestText: "oops").statusCode == 400, "malformed request rejected")
check(string(router.payloads, "/api/mobile/state.json") == string(locked, "/api/mobile/state.json"), "request never changes lock state")
// Revisions are independent of playback selection and volume, including before first guide load.
let stableContext = LocalAPIExportContext(baseURLs: [], visibleChannels: items, generatedAt: nil, sourceStatus: [:], settings: settings, areProtectedChannelsUnlocked: false, selectedChannelID: nil, isPlayerDetached: false)
let stableA = LocalAPIExportRenderer.render(context: stableContext)
settings.volume = 0.1
let stableB = LocalAPIExportRenderer.render(context: .init(baseURLs: [], visibleChannels: items, generatedAt: nil, sourceStatus: [:], settings: settings, areProtectedChannelsUnlocked: false, selectedChannelID: "two::1", isPlayerDetached: true))
check(stableA["/api/mobile/state.json"]!.data == stableB["/api/mobile/state.json"]!.data, "unrelated playback state keeps stable guide revision")
settings.excludedChannelIDsBySource = ["two": ["1"]]
let hidden = LocalAPIExportRenderer.render(context: context(true))
check(!string(hidden, "/api/guide.xmltv").contains("two::1"), "hidden channels filtered defensively")
check(string(open, "/api/playlist.m3u").contains("tvg-id=\"one::1\""), "playlist matches global XMLTV channel IDs")
check(!string(locked, "/api/channels.json").contains("guide.xml"), "upstream guide URL redacted while locked")
let baseTime = Date(timeIntervalSince1970: 2_000)
let bounded = LocalAPIRequestRouter()
bounded.payloads = locked
var count = 0
bounded.onUnlockRequest = { _ in count += 1 }
for index in 0..<11 {
    let code = bounded.route(requestText: "POST /api/mobile/unlock-request?deviceID=\(UUID().uuidString)&deviceName=Device\(index) HTTP/1.1\r\n\r\n", now: baseTime).statusCode
    check(code == (index < 10 ? 202 : 429), "bounded request queue/rate limit")
}
check(count == 10, "queue does not grow on rate limited request")
check(bounded.route(requestText: request, now: baseTime.addingTimeInterval(61)).statusCode == 202, "rate limit expires")
check(router.route(requestText: "POST /api/mobile/unlock-request?deviceID=\(id)&deviceName=x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello").statusCode == 400, "request body rejected")
check(router.route(requestText: "GET /api/state.json#fragment HTTP/1.1\r\n\r\n").statusCode == 400, "fragment rejected")
check(router.route(requestText: "GET / HTTP/1.1\r\n" + String(repeating: "x", count: 17_000)).statusCode == 413, "oversized request rejected")
check(String(data: LocalAPIServer.httpResponse(for: .init(contentType: "text/plain", data: Data("x".utf8), statusCode: 405)), encoding: .utf8)!.hasPrefix("HTTP/1.1 405 Method Not Allowed"), "correct status line")
router.payloads = open
check(router.route(requestText: request).statusCode == 200 && requests.count == 1, "already unlocked request does not requeue")
let unavailable = LocalAPIRequestRouter()
check(unavailable.route(requestText: request).statusCode == 503, "requests rejected before server snapshot ready")
print("Desktop API protocol checks passed")
