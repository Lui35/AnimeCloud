# Anime Cloud for iOS

A native SwiftUI reimplementation of Anime Cloud, built from the recovered 6.5 API contract.

## Included

- Live home, discovery, schedule, detail, episode, comment, and playback flows
- Native iOS video controls with stable fullscreen transitions, movie-playback audio, AirPlay, Picture in Picture, and locally cached per-episode resume positions
- Cancellation-safe playback: dismissing an episode while it is loading cancels the request, detaches the media item, and deactivates audio
- End-of-episode Up Next panel with Play Next, Replay, watched-state updates, and all-caught-up handling
- Four original library categories (Favorites, Watched, Watch Later, Watching Now), watch history, profile/authentication, and automatic legacy-compatible SQLite cloud sync
- A grounded recommendation assistant that only suggests titles returned by the catalog
- Native SwiftUI design, generated app icon, two-stage branded loading experience, Arabic/English content support, and no third-party dependencies

## Open and run

1. Open `AnimeCloud.xcodeproj` in Xcode.
2. Select the **AnimeCloud** scheme and an iPhone running iOS 17 or newer.
3. Choose your Apple Development team under Signing & Capabilities.
4. Build and run.

No third-party package is required. The app uses SwiftUI, URLSession, AVKit, and CommonCrypto.

The project has been compiled and its unit tests run successfully on an iPhone simulator with Xcode 26.5.

Cloud sync is download-first: the app retrieves and merges the server database before any upload. The first login for an account is restore-only, so an empty local library can never replace an existing cloud backup. Later local changes are debounced and synchronized automatically.

## AI integration

`AnimeIntelligenceProviding` is the AI boundary. The included `GroundedDiscoveryService` performs private, deterministic matching against the live catalog. A Firebase AI Logic/Gemini implementation can replace it later while preserving the rule that every returned anime ID must exist in the catalog. Do not embed a Gemini API key in this target.

## Legacy backend warning

The app talks to the original Anime Cloud servers. They use an old command-based PHP API and may change without notice. Account and write operations should be tested with a dedicated test account before production distribution.
