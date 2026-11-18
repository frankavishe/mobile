# Chat App — Android

Flutter client for the Chat App messenger (Android 7.0+ / API 24). Accounts are created here: phone
number + one-time code, then a profile. The same account can then sign in on the web app.

Specs and plans live in the Spec Kit repo one level up (`../specs/`). The API lives in `../api`.

## Requirements

- Flutter 3.44 (stable), Dart 3.12
- An Android emulator or device (API 24+)
- A running API (see `../api/README.md`)

## Run locally

```bash
flutter pub get
flutter run --dart-define=API_URL=http://10.0.2.2:3000
```

`API_URL` is the API origin without `/v1`. `10.0.2.2` is the host machine as seen from the Android
emulator, and that is the default. For a physical device, use your computer's LAN IP. Debug builds
allow plain HTTP (`android/app/src/debug/AndroidManifest.xml`); release builds don't.

One-time codes are printed in the API log (`OTP for +255…: 123456`).

## Tests

```bash
flutter analyze
flutter test                     # unit, widget and contract tests
flutter test integration_test    # on an emulator, with the API running
```

`test/contract_models_test.dart` checks the Dart models against the API contract. It reads
`../api/contracts/`, so check out the api repo next to this one, or set `CONTRACT_DIR`.

## How sessions work

- `POST /auth/verify` returns an access token (15 min) and a refresh token. The refresh token is
  kept in `flutter_secure_storage` (Android Keystore). The access token lives only in memory.
- On start, the app refreshes and then loads `/me` (`SessionNotifier.restore`).
- `ApiClient` retries a request once after a 401, and concurrent 401s share one refresh. The server
  rotates refresh tokens and treats reuse as theft.
- The socket (`/rt`) reconnects with a fresh token after `auth:expired`. `device:revoked` means
  the app must wipe its storage and return to sign-in.

## Layout

```
lib/
  main.dart, app.dart, router.dart   entry point, theme, routes + session redirects
  core/
    config.dart                      API_URL
    theme.dart                       palette (same tokens as the web app)
    api/                             ApiClient (dio) and contract models
    auth/session.dart                session state (Riverpod)
    realtime/socket_service.dart     Socket.IO client
    storage/secure_store.dart        refresh token storage
  features/                          screens, one folder per feature
test/                                unit, widget and contract tests
integration_test/                    end-to-end flows on a device
```
