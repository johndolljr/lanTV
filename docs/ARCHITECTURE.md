# Architecture

## Desktop

`GuideRepository` loads configured XMLTV and HDHomeRun feeds. `GuideViewModel`
owns the merged guide, hidden channels, authenticated protection state, and
playback. `LocalAPIServer` publishes snapshots of that state to the LAN.

The existing JSON, XMLTV, and M3U endpoints remain metadata exports. Stream
addresses point at the original upstream source. No mobile video passes through
the desktop API.

## Mobile connection contract

`Mobile/lanTVMobile.xcodeproj` contains the iPhone/iPad target. `MobileStore`
coordinates sources, state validation, and playback. `MobileCore` contains the
portable XMLTV parser and lock policy, tested by `Mobile/Package.swift`.
`MobileContentView` adapts the guide and player to available width; it uses a
channel list and player sheet on iPhone, and a selected-show header with mini
player above an integrated-search timeline guide on iPad.
The desktop advertises its Local API using Bonjour (`_lantv._tcp`). The mobile
app browses while foregrounded, resolves the host and port, and asks before
adding a discovered desktop as a source. The XMLTV configuration includes each
channel's direct stream URL; mobile selects AVPlayer for HLS and MobileVLCKit for
other network stream formats.

`AppleTV/lanTVAppleTV.xcodeproj` is the dedicated tvOS interface. It compiles
the same `MobileStore` and `MobileCore` sources, preserving Bonjour discovery,
guide caching, source URL validation, and the desktop lock lease. Its guide
follows the iPad arrangement: selected-show information with a live preview
above an integrated-search programme timeline. Fullscreen mode maps Siri Remote
Play/Pause to the active player, Up/Down to programme information, and Menu to
dismiss overlays or exit fullscreen.
HLS and MP4 use AVPlayer; other supported upstream formats use VideoLAN's
tvOS-specific TVVLCKit binary.

`GET /api/mobile/state.json` describes protocol version 1, an opaque `revision`,
`areProtectedChannelsUnlocked`, `protectedChannelCount`, and the XMLTV
`guideURL`. `GET /api/guide.xmltv` contains a matching `lanTV-revision` root
attribute, globally unique channel IDs, and a `<stream-url>` on each channel.
Protected exported channels carry `protected="true"`; while locked they and
their programmes are omitted.

The mobile client verifies the state before and after loading the guide. It
only installs a snapshot when the revisions agree. A foreground poll checks for
changes every two seconds. A changed revision invalidates the old desktop
snapshot before replacement. A failed state check or expired five-second state
lease clears the desktop snapshot and stops its playback: old metadata cannot
reliably identify channels newly marked protected on the Mac. Backgrounding also
invalidates the desktop connection; returning to the foreground requires fresh
desktop state. Independent XMLTV sources do not use this desktop lease.
The client rejects a lanTV aggregate mistakenly entered as an independent XMLTV
source and asks the user to add it as a Desktop Server so lock checks apply.

`POST /api/mobile/unlock-request?deviceID=<UUID>&deviceName=<name>` queues a
request. A pending request returns HTTP 202; an already unlocked desktop returns
HTTP 200. It never directly changes the protection state. The desktop presents
Approve and Deny controls. Approve invokes the existing desktop authentication
flow; only successful local authentication can unlock channels.

The mobile app caches only channels marked unprotected by a revision-validated
desktop guide, including their programme data and direct stream URLs. Protected
channels and their URLs are never written to that cache. When desktop state can
no longer be verified, the app switches to the cached public guide, stops any
protected playback, and permits direct playback only for cached unprotected
channels. It retries the desktop in the background and replaces the cache after
a fresh matching state/guide snapshot arrives. Removing the desktop source also
removes its cache. Hide source templates and protected guide/stream metadata from
locked API exports. A copied upstream stream URL is outside this client-side
lock boundary.

## Networking and playback

App Transport Security permits user-entered HTTP sources, including `.lan`
hosts. `NSAllowsArbitraryLoads` must not be combined with fine-grained ATS keys
that make the OS ignore it. See [Apple's ATS key reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html).

VideoLAN's existing desktop VLCKit binary only contains macOS slices. Mobile
uses a separate MobileVLCKit framework for iOS device and simulator playback,
including upstream broadcast streams; it does not replace the desktop binary.

## Verification

Use synthetic guides and isolated settings. Verify duplicate source channel
IDs, direct upstream URLs, missing or invalid URLs, lock export redaction,
request-only remote access, state revision consistency, relock/failure playback
stopping, compact iPhone layout, and regular-width iPad layout. See
[MANUAL_TEST_PLAN.md](MANUAL_TEST_PLAN.md).
