# Anime Cloud 6.5 API inventory

Source: static analysis of `Anime-Cloud 5.ipa` (`com.animecloud.rm`, app version 6.5), plus non-mutating live requests on 2026-07-25.

## Protocol summary

The app does not use REST-style paths. It sends a `POST` to one of two PHP gateway URLs and selects the operation using a form field named `command`.

| Gateway | Purpose | Live status |
|---|---|---|
| `https://khkhkhkh.com/animecp/animeapi65/` | Catalog, anime, episodes, playback, news, push token, counters | HTTP 200; JSON; nginx; PHP 5.6.40 |
| `https://animecloudapp.com/aanimeApp65/` | Accounts, comments, subscriptions, receipts, uploads/backups | HTTP 200; JSON; Apache |

Requests are compatible with `application/x-www-form-urlencoded` form bodies. The binary repeatedly configures `Content-Type: application/json`, but its actual AFNetworking parameter dictionaries are form-encoded and live form requests work. Responses are JSON unless noted otherwise. There is no app-specific Bearer-token flow. Account authorization uses `userID`/`uniqID` in request bodies.

Common response shape is `{ "result": [...] }`. Some operations use additional top-level keys such as `mainResult`, `SettingsResult`, `result2`, `result3`, and `result4`.

## Catalog gateway commands

All commands in this section use `POST https://khkhkhkh.com/animecp/animeapi65/`.

| `command` | Parameters besides `command` | Purpose / observed result |
|---|---|---|
| `getGenres` | none | Genre rows: `name` |
| `getYears` | none | Available year values |
| `getSeason` | none | Available seasons |
| `getAges` | none | Available age classifications |
| `getMost` | `cmode`, `hiddenMode` | Main/most-popular listing |
| `getByYear` | `name`, `cmode`, `hiddenMode` | Anime filtered by year |
| `getBySeason` | `name`, `cmode`, `hiddenMode` | Anime filtered by season |
| `getByGenres` | `name`, `cmode`, `hiddenMode` | Anime filtered by genre |
| `getByRank` | `cmode`, `hiddenMode` | Ranked listing |
| `getByContinue` | `cmode`, `hiddenMode` | Ongoing anime |
| `getByFinished` | `cmode`, `hiddenMode` | Completed anime |
| `getAllAnime` | `cmode`, `hiddenMode` | Full catalog |
| `getByAge` | `name`, `cmode`, `hiddenMode` | Anime filtered by age |
| `getAllMovies` | `cmode`, `hiddenMode` | Movie catalog |
| `getFavorite` | `favoriteIDs`, `cmode`, `hiddenMode` | Hydrates locally stored favorite IDs |
| `getRelatedAnime` | `animeID`, `rootID`, `cmode`, `hiddenMode` | Related anime |
| `getAnimeWithDays` | `cmode`, `hiddenMode` | Schedule; observed rows contain `id`, `name`, `image`, `status`, `year`, `day` |
| `getNewEpAndAnime` | `cmode`, `hiddenMode` | New episodes/anime; app reads `result`, `result2`, `result3`, `result4` |
| `getAnimeDetails` | `animeID` | Episode list and settings |
| `getAnimeMoreDetails` | `animeID` | Story and genres |
| `getVideoURL` | `epID`, `quality` | Playback payload; response is Base64-wrapped RNCryptor data, not ordinary JSON |
| `getNews` | none | News rows: `id`, `title`, `image`, `content`, `count`, `sh`, `url` |
| `getNewsDetails` | `newsID` | Full news item |
| `updateNewsCount` | `newsID` | Increments a news counter |
| `updateAnimeVisiterCount` | `animeID` | Increments an anime view counter |
| `updateAppVisiterCount` | none | Increments the app visitor counter |
| `saveUsersToken` | `UserToken`, `userDeviceModel`, `userSystem`, `envType` | Saves an APNs/device token |

Catalog list rows observed from `getAllAnime` contain `id`, `name`, `image`, `status`, `year`, and `keywords`.

`getAnimeDetails` was live-tested with `animeID=2571` and returned:

- `mainResult[]`: `age`, `rank`, `relatedID`
- `result[]` episode rows: `id`, `name`, `image170`, `image300`, `filer`, `enableComment`
- `SettingsResult`: `version`, `EnablePurchase`, `EnableDownload`, `HidePlayButton`, `AdType`, `mm`, `showPurchaseButtonForRigserUserOnly`, and nested `message`

`getAnimeMoreDetails` returned `result[]` rows containing `story` and `genres`.

The `getVideoURL` response is decoded by Base64-decoding it and then using RNCryptor with the password embedded in the client: `anime5w&f4H&434*`. The decrypted object is expected to expose playback fields including `url` and `note`. `quality` is supplied by the UI; exact accepted quality values were not proven from static analysis.

## Account/comment gateway commands

All commands in this section use `POST https://animecloudapp.com/aanimeApp65/`.

| `command` | Parameters besides `command` | Purpose |
|---|---|---|
| `userLogin` | `email`, `password` | Login |
| `userSignup` | `username`, `email`, `password`, `token` | Registration; `token` is sourced from local `userToken` and can be empty |
| `activateUserAccount` | `code`, `email`, `password` | Account activation |
| `recoverPassword` | `email` | Password recovery |
| `changeUsername` | `userID`, `uniqID`, `newUsername`, `oldUsername` | Change username |
| `changeUserPassword` | `userID`, `uniqID`, `oldPassword`, `newPassword` | Change password |
| `getSubscribeDays` | `userID`, `uniqID` | Subscription days/status |
| `validateRecipte` | `recipt`, `transactionID`, `productID`, `userID`, `uniqID` | Validates an in-app purchase receipt (misspellings are exact) |
| `getAnimeComments` | `offset`, `animeID`, `orderBy` | Anime-level comments |
| `getComments` | `offset`, `epID`, `orderBy` | Episode comments |
| `getCommentsRuls` | none | Comment rules (misspelling is exact) |
| `addComment` | `epID`, `userID`, `uniqID`, `content`, `animeName`; episode flow also sends `epName` | Add comment |
| `updateComment` | `commentID`, `userID`, `uniqID`, `content`, `epName`, `animeName` | Edit comment |
| `deleteComment` | `commentID`, `userID`, `uniqID` | Delete comment |
| `reportComment` | `commentID`, `userID`, `uniqID` | Report comment |
| `addlike` | `commentID`, `userID`, `uniqID` | Like comment |
| `addDisLike` | `commentID`, `userID`, `uniqID` | Dislike comment |
| `uploadProfilePicture` | `uid`, `uniqID`, multipart file field `file` | Upload profile picture |
| `saveBackup` | `uid`, `uniqID`, multipart file field `fileToUpload` | Upload local SQLite sync backup |

Login response fields referenced by the app include `status`, `userid`, `email`, `profilePicture`, `confirm`, `uniqid`, `username`, `subscribe`, and `hash`. The app stores `userid` and `uniqid` locally and sends them as `userID` and `uniqID` for authenticated operations.

Upload details:

- Profile image: multipart field `file`, filename `temp.jpeg`, MIME type `image/jpeg`.
- Backup: multipart field `fileToUpload`, filename `animeDB.sqlite`, MIME type `application/octet-stream`.

## Direct files and auxiliary URLs

| Method / URL | Purpose |
|---|---|
| `GET https://animecloudapp.com/message.json` | Offline/global app message |
| `GET https://animecloudapp.com/usersBackup/{uid}-{uniqid}.sqlite` | Downloads a user's SQLite sync backup |
| `GET https://khkhkhkh.com/test/up/animeDB.sqlite` | Downloads a seed/update SQLite database |
| `https://animecloudapp.com/` | Base used to construct the backup download URL |
| `animecloudkhapp://?myurlurl={...}&ePID={...}&animeID={...}&fileURL=khkhkhkh.com/animecp/animeapi4/` | Legacy external-player deep link |

## Local sync model

The app does not expose a record-by-record cloud sync API. It maintains a local `animeDB.sqlite` and uploads/downloads the whole database as the user backup. Relevant local tables are:

- `Favor(id, animeID, favType)`
- `Seen(id, epID, animeID)`
- `lastSeenArray(id, animeID)`
- `reportedComments(id, commentID)`

This means a replacement app can use the catalog APIs independently, but compatibility with existing user sync requires understanding and preserving this SQLite schema and the `saveBackup`/backup-download convention.

## Reproduction examples

```bash
curl --data-urlencode 'command=getGenres' \
  'https://khkhkhkh.com/animecp/animeapi65/'

curl --data-urlencode 'command=getAnimeDetails' \
  --data-urlencode 'animeID=2571' \
  'https://khkhkhkh.com/animecp/animeapi65/'
```

## Confidence and caveats

- High confidence: gateway URLs, command names, request field names, HTTP method, multipart field names, direct-file URLs, and the tested catalog response fields.
- Medium confidence: commands whose request dictionaries are built dynamically (`getMost` and the filter/list variants); their field mappings were reconstructed from the controller branches and call sites.
- Not tested: login/account mutation, comment mutation, receipt validation, uploads, counters, push-token writes, and encrypted playback. These were intentionally left untouched.
- The IPA is patched/sideload-oriented: its executable weak-loads `animecloudisfunny.dylib`, `ACplus.dylib`, and `libSubstitute.dylib`, and bundles CydiaSubstrate. The main executable itself is decrypted (`cryptid 0`), which made this static inventory possible.
