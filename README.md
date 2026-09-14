# Anime Cloud for iOS

A native SwiftUI reimplementation of Anime Cloud, built from the recovered 6.5 API contract.

## Included

- Live home, discovery, schedule, detail, episode, comment, and playback flows
- Restored New Episodes home rail backed by the legacy live feed, with the latest episode label on every card
- A Related Series button on every anime preview, with sequel/prequel cards that open their complete preview pages
- Native iOS video controls with stable fullscreen transitions, movie-playback audio, AirPlay, Picture in Picture, and locally cached per-episode resume positions
- Cancellation-safe playback: dismissing an episode while it is loading cancels the request, detaches the media item, and deactivates audio
- Use each episode’s three-dot menu to mark it watched or unwatched, with cloud-safe removal syncing
- End-of-episode Up Next panel with Play Next, Replay, watched-state updates, and all-caught-up handling
- Four original library categories (Favorites, Watched, Watch Later, Watching Now), watch history, profile/authentication, and automatic legacy-compatible SQLite cloud sync
- Optional AniList OAuth connection with download-first status sync and highest-watched-episode progress; access tokens are stored in iOS Keychain
- A grounded recommendation assistant that only suggests titles returned by the catalog
- Native SwiftUI design, generated app icon, two-stage branded loading experience, Arabic/English content support, and no third-party dependencies

## Open and run

1. Open `AnimeCloud.xcodeproj` in Xcode.
2. Select the **AnimeCloud** scheme and an iPhone running iOS 17 or newer.
3. Choose your Apple Development team under Signing & Capabilities.
4. Build and run.

No third-party package is required. The app uses SwiftUI, URLSession, AVKit, and CommonCrypto.

The project has been compiled and its unit tests run successfully on an iPhone simulator with Xcode 26.5.

## CI and unsigned IPA releases

Pull requests into `main` and pushes to `main` run the **Main CI / Build and test** check. The pipeline runs the unit tests, builds an unsigned device app, packages it as `AnimeCloud-unsigned.ipa`, and retains it as a workflow artifact for 14 days.

Pushing a semantic version tag such as `v1.0.0` runs the release workflow and attaches `AnimeCloud-v1.0.0-unsigned.ipa` to a GitHub Release. The workflow can also be started manually with a semantic version tag. The IPA contains an unsigned `Payload/AnimeCloud.app`, with any signature and provisioning profile removed, so a compatible container or sideloading tool can sign it at install time.

The same artifact can be built locally:

```sh
Scripts/build-unsigned-ipa.sh
```

Protect the `main` branch in GitHub with the **Main CI / Build and test** status check required, pull requests required, stale approvals dismissed, force pushes disabled, and branch deletion disabled. Branch protection is a repository setting and is not controlled by workflow YAML.

Cloud sync is download-first: the app retrieves and merges the server database before any upload. The first login for an account is restore-only, so an empty local library can never replace an existing cloud backup. Later local changes are debounced and synchronized automatically.

## Optional AniList setup

1. In AniList developer settings, create an API client with redirect URL `animecloud://anilist-auth`.
2. In Anime Cloud, open **You → AniList sync**, enter the numeric client ID, and authorize.
3. The first connection downloads only. Later changes to Watching Now, Watch Later, Watched, and episode progress sync automatically after downloading AniList first.

AniList only exposes aggregate episode progress, so Anime Cloud keeps its detailed watched-episode set locally and sends the highest watched episode. Favorites remain local. Exact title/year matches are linked automatically; ambiguous matches are skipped.

## AI integration

`AnimeIntelligenceProviding` is the AI boundary. The included `GroundedDiscoveryService` performs private, deterministic matching against the live catalog. A Firebase AI Logic/Gemini implementation can replace it later while preserving the rule that every returned anime ID must exist in the catalog. Do not embed a Gemini API key in this target.

## Legacy backend warning

The app talks to the original Anime Cloud servers. They use an old command-based PHP API and may change without notice. Account and write operations should be tested with a dedicated test account before production distribution.
