import XCTest
@testable import MobileCore

final class MobileCoreTests: XCTestCase {
    func testAggregateParsesGlobalIDsStreamAndProtection() throws {
        let xml = """
        <tv lanTV-revision="r1"><channel id="a|1" protected="true"><display-name>News &amp; More</display-name><stream-url>http://tvserver.lan:8000/video?channel=1&amp;x=2</stream-url></channel><programme channel="a|1" start="20261108120000 +0000" stop="20261108130000 +0000"><title>Morning</title></programme></tv>
        """
        let guide = try MobileXMLTVParser.parse(Data(xml.utf8), sourceID: UUID(), template: "")
        XCTAssertEqual(guide.revision, "r1")
        XCTAssertThrowsError(try MobileLockPolicy.validateStandaloneGuide(guide))
        XCTAssertEqual(guide.channels.first?.name, "News & More")
        XCTAssertEqual(guide.channels.first?.streamURL?.host, "tvserver.lan")
        XCTAssertEqual(guide.channels.first?.isProtected, true)
        XCTAssertEqual(guide.channels.first?.programmes.first?.title, "Morning")
    }
    func testStandaloneTemplateEscapesChannelAndSupportsFractionalNumber() throws {
        let xml = "<tv><channel id=\"a b&amp;c\"><display-name>7.2 Family</display-name></channel></tv>"
        let guide = try MobileXMLTVParser.parse(Data(xml.utf8), sourceID: UUID(), template: "http://tuner.lan/video?channel={channel}")
        XCTAssertEqual(guide.channels.first?.number, "7.2")
        XCTAssertNoThrow(try MobileLockPolicy.validateStandaloneGuide(guide))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(guide.channels.first?.streamURL), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a b&c")
    }
    func testBadXMLFailsAndLoopbackRejected() {
        XCTAssertThrowsError(try MobileXMLTVParser.parse(Data("<tv>".utf8), sourceID: UUID(), template: ""))
        for host in ["localhost", "127.0.0.1", "127.1.2.3", "[::1]", "0.0.0.0"] {
            XCTAssertThrowsError(try MobileSource.validatedURL("http://\(host):8000"))
        }
        XCTAssertNoThrow(try MobileSource.validatedURL("http://tvserver.lan:8000"))
    }
    func testLockReconciliationFailsClosedAndRevisionRaceRejected() throws {
        let channel = MobileChannel(sourceID: UUID(), rawID: "1", number: "1", name: "Protected", streamURL: URL(string: "http://tuner.lan/1"), logoURL: nil, isProtected: true, programmes: [])
        let unlocked = DesktopState(protocolVersion: 1, revision: "r1", areProtectedChannelsUnlocked: true, protectedChannelCount: 1, guideURL: "/api/guide.xmltv")
        let locked = DesktopState(protocolVersion: 1, revision: "r2", areProtectedChannelsUnlocked: false, protectedChannelCount: 1, guideURL: "/api/guide.xmltv")
        XCTAssertTrue(MobileLockPolicy.canPlay(channel, state: unlocked, validatedAt: Date()))
        XCTAssertEqual(MobileLockPolicy.allowedChannels([channel], state: unlocked), [channel])
        XCTAssertEqual(MobileLockPolicy.allowedChannels([channel], state: locked), [])
        XCTAssertFalse(MobileLockPolicy.canPlay(channel, state: locked, validatedAt: Date()))
        XCTAssertFalse(MobileLockPolicy.canPlay(channel, state: unlocked, validatedAt: Date().addingTimeInterval(-10)))
        XCTAssertFalse(MobileLockPolicy.canPlay(channel, state: nil, validatedAt: nil))
        XCTAssertThrowsError(try MobileLockPolicy.validate(before: unlocked, guideRevision: "r1", after: locked))
        XCTAssertNoThrow(try MobileLockPolicy.validate(before: unlocked, guideRevision: "r1", after: unlocked))
    }
    func testSnapshotInvalidatedForReclassificationOrUnknownState() {
        let state = DesktopState(protocolVersion: 1, revision: "new", areProtectedChannelsUnlocked: false, protectedChannelCount: 1, guideURL: "/api/guide.xmltv")
        XCTAssertTrue(MobileLockPolicy.mustInvalidateSnapshot(previousRevision: "old", newState: state))
        XCTAssertTrue(MobileLockPolicy.mustInvalidateSnapshot(previousRevision: "old", newState: nil))
        XCTAssertFalse(MobileLockPolicy.mustInvalidateSnapshot(previousRevision: "new", newState: state))
        let unsupported = DesktopState(protocolVersion: 2, revision: "new", areProtectedChannelsUnlocked: true, protectedChannelCount: 1, guideURL: "/api/guide.xmltv")
        XCTAssertTrue(MobileLockPolicy.mustInvalidateSnapshot(previousRevision: "new", newState: unsupported))
    }
    func testMissingStreamEmptyNamesRelativeLogoAndInvalidProgramme() throws {
        let xml = """
        <tv><channel id="2"><icon src="/logo.png"/></channel><channel id="1"><display-name>One</display-name><stream-url>http://tv.lan/one</stream-url></channel><programme channel="1" start="garbage" stop="garbage"><title>Invalid</title></programme><programme channel="2" start="202611081200 +0000" stop="202611081300 +0000"><desc>Detail</desc></programme><programme channel="2" start="20261108140000" stop="20261108130000"/></tv>
        """
        let source = UUID()
        let guide = try MobileXMLTVParser.parse(Data(xml.utf8), sourceID: source, template: "", baseURL: URL(string: "http://tv.lan/guide.xml"))
        let channel = try XCTUnwrap(guide.channels.first { $0.rawID == "2" })
        XCTAssertNil(channel.streamURL)
        XCTAssertEqual(channel.name, "2")
        XCTAssertEqual(channel.number, "2")
        XCTAssertEqual(channel.logoURL?.absoluteString, "http://tv.lan/logo.png")
        XCTAssertEqual(channel.programmes.count, 1)
        XCTAssertEqual(channel.programmes.first?.title, "Programme")
        XCTAssertEqual(channel.programmes.first?.detail, "Detail")
        XCTAssertNil(channel.nowPlaying)
        XCTAssertFalse(channel.id.isEmpty)
        XCTAssertFalse(channel.programmes.first!.id.isEmpty)
        XCTAssertThrowsError(try MobileXMLTVParser.parse(Data("<html/>".utf8), sourceID: source, template: ""))
    }
    func testSourceValidationAndDatesWithoutZone() throws {
        XCTAssertThrowsError(try MobileSource.validatedURL("file:///private/foo"))
        XCTAssertThrowsError(try MobileSource.validatedURL("http://user:secret@tv.lan"))
        XCTAssertThrowsError(try MobileSource(name: "Bad", kind: .xmltv, url: "http://tv.lan/g.xml", streamTemplate: "http://localhost/{channel}").validated())
        let source = MobileSource(name: "TV", kind: .desktop, url: "https://tv.lan", streamTemplate: "")
        XCTAssertEqual(try source.validated(), source)
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(MobileSource.self, from: data), source)
        let xml = "<tv><channel id=\"abc\"><display-name>Alpha</display-name></channel><programme channel=\"abc\" start=\"20261108120000\" stop=\"20261108130000\"><title>Show</title></programme><programme channel=\"abc\" start=\"202611081300\" stop=\"202611081400\"><title>Next</title></programme></tv>"
        let guide = try MobileXMLTVParser.parse(Data(xml.utf8), sourceID: UUID(), template: "")
        XCTAssertEqual(guide.channels.first?.programmes.count, 2)
        XCTAssertEqual(guide.channels.first?.number, "")
        XCTAssertEqual(MobileError.message("Test").localizedDescription, "Test")
    }

}
