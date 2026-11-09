# lanTV project context

lanTV is a local-network TV guide and player for macOS, iPhone, and iPad.
The Mac aggregates XMLTV and HDHomeRun sources. The mobile app can connect to
that aggregate or load independent XMLTV feeds.

## Product decisions

- The Mac supplies metadata and original stream addresses; mobile video goes
  directly to the upstream TV source. The Mac does not proxy or transcode it.
- iPhone uses a compact browsing and playback layout. iPad uses its available
  width for browsing beside the player. Both follow the desktop's dark navy,
  rounded-card, blue-accent appearance.
- Protection is one shared desktop-controlled state. A mobile unlock request
  cannot grant access. Someone must approve on the Mac and pass the Mac's
  existing system authentication. Relocking on the Mac applies to mobile too.
- A mobile or TV device may request unlock-approver rights. The desktop requires
  local authentication before granting those rights, stores an approver
  credential hash, and keeps a revocable device inventory in Settings.
  Authorized devices poll the desktop over the LAN while active and can approve
  or deny unlock requests; approval updates the same desktop lock state. An
  authorized device can use its registered key to approve its own unlock request
  without invoking the desktop's local authentication prompt.
- Mobile checks desktop state while active and removes protected content when
  state cannot be verified. Backgrounding must stop protected playback.
- Source URLs must be reachable from the device that plays them. `localhost`
  refers to that device, so use the source's actual LAN hostname or IP address.
- User-entered HTTP TV feeds include arbitrary `.lan` hosts. They must work
  without rebuilding for each hostname. Transport exceptions do not fix DNS,
  firewall, local-network permission, or source availability problems.

## Protection boundary

The lock governs lanTV's exported metadata and cooperating mobile client. Direct
streaming cannot revoke an upstream address already copied to another player.
Independent XMLTV sources are outside the desktop's lock authority. Use source
server authentication or network controls if upstream access must be enforced
independently of lanTV. The local API is intended for a trusted LAN.

## Development constraints

Follow AGENTS.md. Stay on the current branch; do not commit or interact with
GitLab without explicit user instructions. Preserve unrelated working changes.
Use isolated synthetic sources for tests and screenshots.
