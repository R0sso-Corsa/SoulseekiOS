# SoulseekiOS

A native iOS client for the [Soulseek](https://www.slsknet.org) peer-to-peer music network — SwiftUI + Liquid Glass, written from scratch in Swift 6 against the reverse-engineered protocol. Built as a personal sideload app (not App Store material, see below).

## Features

- **Search** the network with live streaming results; filters for bitrate (presets + custom), free slots, lossless, and bit depth; per-user and per-room scoped searches
- **Downloads** that work behind NAT: indirect connection brokering, queue positions, byte-offset resume, pause/resume on app backgrounding, Wi-Fi-only policy and speed limits
- **Library** of completed downloads: sort, delete, share-out, storage stats, and a **preview player** with play/pause/scrub/±15s that tells you whether a file plays cleanly or is corrupted
- **Sharing / uploads**: share folders, slot limits, direct and indirect upload paths, NAT-PMP port mapping where the network allows it
- **Chat**: private messages, public groups, and the full **private-room suite** (create invite-only groups, invite with auto-join, operators, kick, disband); room tickers, buddy list with live status, group browser with search
- **Music cards**: share a downloadable file into any chat; recipients pull it over the normal transfer path
- **Photos & videos in chat** between users of this app (the file rides the standard transfer path; other clients see a plain text line)
- **Wishlist**: saved searches re-run automatically on the server's interval
- **Persistence**: chats, groups, and history survive restarts; groups rejoin automatically; credentials in the Keychain with seamless session restore

## Requirements

- macOS with **Xcode 27 beta** (iOS 26 SDK) — the UI uses Liquid Glass (`glassEffect`), iOS 26+ only
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An iPhone with Developer Mode enabled, and an Apple developer team (a free personal team works; the signing profile expires after 7 days and needs a rebuild)
- A Soulseek account (unknown usernames auto-register on first login)

## Build & run

```sh
git clone https://github.com/R0sso-Corsa/SoulseekiOS.git
cd SoulseekiOS
xcodegen generate
```

Open `SoulseekiOS.xcodeproj`, set your own `DEVELOPMENT_TEAM` in `project.yml` (the committed value is the original author's), regenerate, and run on your device.

## Tests

The project is developed test-first: protocol codecs against golden bytes, engine tests over a loopback fake server, and XCUITest acceptance flows.

```sh
swift test --skip Live        # deterministic codec + engine suites (no network)
```

Live-network tests are opt-in: set `SLSK_USER` / `SLSK_PASS` to a **throwaway** account (unknown usernames auto-register) and run `swift test --filter Live`. UI tests run via `xcodebuild build-for-testing` + `test-without-building` on a simulator; live credentials are injected through the `.xctestrun` environment.

## Protocol notes

The Soulseek protocol is undocumented officially; this implementation was built against the community documentation of [aioslsk](https://aioslsk.readthedocs.io) and [Nicotine+](https://github.com/nicotine-plus/nicotine-plus), with every message layout verified against golden bytes and live traffic. Notable behaviors discovered live (documented in the code):

- The server only lists public rooms with 5+ members
- Private-room invites to offline users are silently dropped; recipients must have invitations enabled (code 141)
- The server stores no room message history — clients keep their own logs
- Two firewalled peers cannot transfer (a protocol limit shared by all clients); transfers fail gracefully with retry

## Distribution

App Store Guideline 5.2.3 bars file-sharing clients of this kind, so this is a **sideload / personal development build** only. Be considerate of the network: it's volunteer-run and donation-funded.

## License

[MIT](LICENSE)