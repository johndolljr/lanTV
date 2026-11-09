# Manual test plan

Use synthetic guide data and temporary settings; do not modify daily-use
sources. An unchecked item has not yet been observed successfully.

## Verification record — 2026-11-08

- Passed isolated real-network checks using the production desktop API server:
  state and XMLTV revisions agree; protected channel metadata is omitted while
  locked; exported stream addresses point directly upstream; a mobile POST queues
  a desktop callback without unlocking; fragmented HTTP headers are handled;
  synthetic desktop unlock/relock updates the exported guide.
- Passed a round trip from that server's actual XMLTV through the mobile parser,
  retaining programme schedules, direct upstream addresses, and the revision.
- Rendered and inspected the desktop approval banner using its production SwiftUI
  content and button style with a synthetic device request. Text and buttons are
  readable. This does not verify live button handling or system authentication.
- Installed and launched the app in iPhone and iPad simulators.
  Inspected the compact channel list and the iPad's inline player plus timeline.
  The iPhone loaded the synthetic desktop through `tvserver.lan` successfully.
- Observed actual MPEG-TS test-pattern playback on iPad with the unlocked
  synthetic desktop guide. The separate upstream server logged the direct video
  request. After fixture desktop relock, the app showed Locked, removed the
  protected channel and details, and replaced the player with its empty state.
- Observed direct MPEG-TS playback in the iPhone's compact player sheet too.
  The earlier implementation cleared guide and playback on desktop loss; the
  offline public-guide cache changes that behavior, so its recovery checks below
  remain unchecked.
- Desktop Debug, iOS Simulator Debug, and unsigned iOS device Release builds
  passed. Seven mobile core tests passed with 92.68% region, 97.66% line, and
  94.64% function coverage. Desktop API assertions passed, but their isolated
  report covers only 51.56% of regions, 51.47% of lines, and 45.74% of functions
  in LocalAPIServer.swift. Live network checks are not merged into that profile;
  whole-app desktop/UI coverage does not meet the shared coverage requirements.
- Physical-device playback, actual Mac system-authentication approval, rotation,
  standalone source editing/persistence through the UI, and background/foreground
  interactions remain unverified. Independent source/security review found no
  remaining blocking issues.

## Desktop sources and settings

- [ ] Channel Rules starts collapsed for each source, counts remain visible,
      and expanding one source does not expand another.
- [ ] Settings actions and source-type selection have readable selected,
      unselected, pressed, and disabled appearances.
- [ ] Add an HTTP XMLTV feed at a `.lan` hostname not known at build time;
      fetch the guide and play its configured direct stream.
- [ ] Use a reachable LAN stream hostname rather than localhost; confirm the
      export preserves its host, port, path, and query.
- [ ] Confirm a source with loopback-only addresses provides clear guidance
      before attempting mobile use.

## iPhone and iPad

- [x] Launch on iPhone, connect to the Mac's LAN address, and load its guide.
- [ ] Browse channels and programmes, select a channel, and play directly from
      the upstream server. Confirm the Mac is serving metadata only.
- [ ] On the iPad mini player and fullscreen player, use visible Play/Pause,
      Full Screen/Exit, and Stop controls with both AVPlayer and VLC streams.
- [ ] Cold-start an HLS/Pluto stream on iPhone and iPad; confirm audio starts
      without opening another video first, including with the phone's silent
      switch enabled.
- [ ] On iPad, confirm the lanTV title, source controls, current channel/show
      information, and mini player share one header above a full-width guide.
- [ ] In the iPad and Apple TV guides, confirm the full timeline is scrollable
      horizontally and vertically, and that more than the initially visible
      hours and channels can be reached.
- [ ] Rotate each device and use iPad's narrow window; controls remain usable
      and long titles do not obscure essential actions.
- [ ] Add an independent XMLTV source and stream URL template, reload the app,
      and confirm source configuration persists.
- [ ] Test an unavailable server and malformed guide; show a readable error
      with a working retry action.
- [ ] Load a desktop guide, stop the desktop API, and relaunch the mobile app;
      cached unprotected channels and programme data remain available.
- [ ] Disconnect the desktop during unprotected playback; keep the direct
      upstream stream playing, then reconnect and confirm the guide refreshes.

## Shared protection

- [ ] While a protected channel is selected, lock on the desktop; playback must
      stop, the protected selection must clear, and window reappearance or a
      delayed player callback must not restart that stream.
- [ ] Lock on Mac; protected names, programmes, and stream URLs disappear from
      desktop exports and mobile.
- [ ] Request unlock on mobile. Confirm the Mac displays the requesting device
      and the mobile remains locked while awaiting approval.
- [ ] Deny on Mac; no protected channels are disclosed.
- [ ] Approve on Mac but cancel/fail system authentication; remain locked.
- [ ] Approve and authenticate on Mac; both devices show the shared unlocked
      state and mobile can load protected channels.
- [x] Start protected playback on mobile and relock on Mac; mobile stops it
      and removes protected metadata on the next state check.
- [ ] Disconnect mobile from the Mac during protected playback; stop playback
      and ensure protected channels and their URLs are absent from the offline
      cache.
- [ ] Background mobile during protected playback, relock Mac, and reopen;
      protected playback must not resume using cached state.
- [ ] Send repeated or malformed unlock requests; the desktop remains usable,
      the request queue is bounded, and requests never unlock directly.
- [ ] From an unregistered mobile/TV device, request approver rights. Confirm
      the desktop prompts for its existing system authentication and the device
      remains pending until the desktop grants access.
- [ ] Confirm an approved device appears in Desktop Settings > Approvers;
      revoke it and verify it can no longer receive or approve requests.
- [ ] From an authorized mobile/TV device, request an unlock from another
      device. Confirm the approver receives a prompt over the LAN, Deny leaves
      the desktop locked, and Approve changes the shared lock state. Keep the
      approver app foregrounded and confirm the request stays visible with
      an immediate dialog with Approve and Deny controls until handled.
- [ ] Deny an unlock request and immediately submit another; verify the next
      request reaches the desktop and authorized mobile approvers.
- [ ] From an authorized phone, tap Unlock while the desktop is locked;
      confirm the phone's registered key approves the request and unlocks the
      desktop without a desktop authentication prompt. A non-approver must still
      require desktop authentication.
- [ ] With channels unlocked on the desktop, use the approver phone's Settings
      to lock them. Confirm desktop and device guide state relocks and protected
      playback stops on both mobile and desktop.
- [ ] Confirm the phone, iPad, and TV guide screens do not show lock status,
      protected-channel counts, or outgoing unlock controls; those controls are
      available only in Settings.
- [ ] Disconnect the desktop from an authorized approver; confirm it cannot
      approve offline or use stale pending requests after reconnecting.

## Apple TV

- [ ] Build and launch `AppleTV/lanTVAppleTV.xcodeproj` on a tvOS simulator and
      physical Apple TV; allow local network access and accept desktop discovery.
- [ ] Select channels with the Siri Remote; confirm focus is visible and the
      selected channel starts in the guide preview without opening another view.
- [ ] Enter fullscreen, pause and resume with the remote, swipe up for current
      programme details, swipe down to dismiss them, and press Menu to exit.
- [ ] Open playback settings while watching; confirm the active stream remains
      uninterrupted and stop/resume controls respond.
- [ ] Play HLS/MP4 and a non-HLS transport stream; confirm both video and audio
      work after switching channels and entering/exiting fullscreen.
- [ ] Verify guide cache during desktop outage; public channels remain visible
      and playable, while protected channels stay unavailable until the desktop
      revalidates its current unlock state.
- [ ] Request a protected-channel unlock from Apple TV and confirm the desktop
      must approve it and that relocking removes protected access on the TV.
