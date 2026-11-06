# Downtify iOS

This SwiftUI foundation runs as an iPhone and iPad app targeting iOS 17 and later. The opening screen identifies the build and explains that server setup is unavailable. The only wire contract in this foundation is the audited subset of the public mobile API v1 server-info response. The tests use synthetic fixtures based on the parity audit.

## Build and test on a Mac

Open `Downtify.xcodeproj` with Xcode 15 or later. Install an iOS simulator runtime in Xcode Settings, choose the shared **Downtify** scheme and an iPhone or iPad simulator, then use **Product → Run** and **Product → Test**. Simulator builds do not need a development team.

For command-line validation, use an available simulator UDID from the listing.

```sh
xcrun simctl list devices available
xcodebuild -project Downtify.xcodeproj -scheme Downtify -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' clean build test
```

The Xcode build, simulator launch and XCTest run are pending macOS validation. This workspace is on Windows.

## Boundaries and platform decisions

- **App** owns composition. The SwiftUI App holds a single container across scenes. Add concrete adapters at this boundary as their features land and pass feature dependencies through initializers. Presentation owns scene and main-actor UI state. Future playback and transfer coordinators should be process-scoped, with their mutable state isolated from views.
- **Presentation** receives domain values and feature protocols as those are introduced. **Network/V1** owns wire names and decoding. Transport and DTO-to-domain mapping belong at the network and repository boundaries. Add **Domain**, **Data** and **Playback** groups when they have concrete responsibilities.
- Use system SQLite through `SQLite3` for the synced library and durable operations. Keep the connection behind an isolated store. Apply ordered schema migrations in transactions and test upgrades from supported versions. A failed migration should preserve the database and surface a recovery state. Only explicitly rebuildable data can be discarded and resynced.
- Put durable data and offline media in Application Support, separate from purgeable stream and artwork caches. Exclude redownloadable media and database state from backup while preserving durable user-created state. Use complete-until-first-user-authentication file protection where background access after unlock is required and complete protection for foreground-only sensitive files. Protect database sidecars alongside the database. Store the device token in Keychain with after-first-unlock, this-device-only accessibility if background authentication is required.
- Use the SwiftUI scene lifecycle for foreground refresh and state persistence as those features land. Add background modes and any delegate callbacks with the playback and transfer implementations that require them.

## Project documents

- [Porting plan](docs/PORTING_PLAN.md)
- [Android parity audit](docs/ANDROID_PARITY_AUDIT.md)
- [Agent handoffs](agents/README.md)
