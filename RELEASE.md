# Releasing react-native-ble-nitro (EngineMon fork)

This fork is **not published to npm**: the name `react-native-ble-nitro` on npm belongs to upstream ([zykeco/react-native-ble-nitro](https://github.com/zykeco/react-native-ble-nitro)). A release is a git tag on `main` plus a GitHub release. Consumers install a tag from GitHub (`npm install github:EngineMon/react-native-ble-nitro#vX.Y.Z`), which builds the package on install, or pin a commit as a git submodule.

`main` is never rebased or force-pushed, and tags are never moved: consumers pin both.

## 📋 Pre-Release Checklist

### 1. Code Quality & Testing
- [ ] All JS tests pass: `npm test`
- [ ] Linting passes: `npm run lint`
- [ ] TypeScript compilation successful: `npm run typecheck`
- [ ] Nitro code generation works: `npm run nitro-codegen` (nitrogen, then the FastNative strip step)
- [ ] The full build works: `npm run build`
- [ ] Kotlin unit tests pass: `cd example/android && ./gradlew :react-native-ble-nitro:testDebugUnitTest`
- [ ] Swift core tests pass: `swift test` in the repository root (macOS or Linux)
- [ ] The example app works on a real iOS and Android device

### 2. Documentation Review
- [ ] README.md is up-to-date, including the migration section for breaking changes
- [ ] The release history below has an entry for the new version
- [ ] The doc comments in `src/specs/NativeBleNitro.nitro.ts` (the native contract) match both implementations
- [ ] CONTRIBUTING.md has correct setup instructions

### 3. Version Management
- [ ] Choose the bump by semver: breaking API changes bump the major version. `npm version` updates `package.json`, which the podspec reads.

## 🔄 Release Workflow

```bash
# 1. Ensure a clean working directory on an up-to-date main
git status
git pull --ff-only

# 2. Run the full build and tests
npm run build && npm test

# 3. Bump the version: rebuilds, commits "X.Y.Z" and tags vX.Y.Z
npm version minor   # or patch/major

# 4. Push the commit and only the new tag
git push origin main vX.Y.Z

# 5. Create the GitHub release
gh release create vX.Y.Z --title "vX.Y.Z" --notes-file notes.md
```

Push the new tag by name rather than with `--tags`: a clone that fetched upstream's tags would otherwise push upstream's `v1.x` tags into the fork.

## 🔀 Merging upstream changes

See [Syncing with zykeco upstream](./CONTRIBUTING.md#-syncing-with-zykeco-upstream). After a merge, run the full checklist above before tagging.

## Release history

### 3.0.0

Breaking. See [Migrating from 2.x to 3.0](./README.md#migrating-from-2x-to-30).

- Subscriptions add up: any number per characteristic, each with an id and an optional end callback. The CCCD is written on with the first subscriber of a link and off after the last. `unsubscribeFromCharacteristic` takes the subscription id; the characteristic-keyed JS method is removed.
- Subscriptions end, with their end callback, on link loss, `disconnect()`, operation timeout, Service Changed and, on Android, a failed service discovery.
- After `destroy()` is called no listener fires, links close silently, and every completion fails once with `BluetoothManagerDestroyed`, also one whose answer was already on its way. Called off the manager's thread, `destroy()` waits until a running listener returned.
- An operation the device doesn't answer within 30 s takes the link down.
- Writes are limited to 512 bytes, and writes without response to `min(MTU - 3, 512)`, before anything is sent. New `getMtu()`.
- Operations check the characteristic's declared properties. New `getCharacteristicProperties()`. A failed CCCD write is 403 on both platforms.
- `discoverServices` discovers characteristics on both platforms; `discoverServicesWithCharacteristics` and `OperationResult` are removed from the native spec.
- Service Changed (Android 12+, iOS): subscriptions on the changed services end with 303, operations on them fail with 303 until the next discovery, and a `ServicesChanged` connection event fires.
- New connection events (`onConnectionEvent`, `subscribeToConnectionEvents`): `Connected`, `Disconnected`, `ServicesChanged`. State listeners are registered natively one per listener, with ids.
- iOS: calls made before the first Bluetooth state wait for it; `connect()` takes over a connection attempt the OS keeps pending (e.g. restored) and its timeout never cancels it; reads of a notifying characteristic are documented as a platform limit.
- Android: a JS reload destroys every manager of the old runtime; `requestBluetoothEnable()` waits for the user's answer; scan results prefer the advertised name; Android 14+ MTU requests complete with the current MTU; `getConnectedDevices` follows its documented per-platform rules.
- Strict UUID parsing, the same forms in JS and in the native API, and write input checks (`ArrayBufferView` accepted, `number[]` entries must be integers from 0 to 255). `connect()` and `findAndConnect()` resolve with the canonical device id.
- `@FastNative` is stripped from the generated Kotlin callback classes after every nitrogen run, and the Android build fails while a generated file still mentions `FastNative` in any form. nitrogen is pinned to 0.35.2, and the `react-native-nitro-modules` peer range is `~0.35.0`.
- Expo plugin: legacy Bluetooth permissions capped at API 30, `neverForLocation` caps the location permissions it adds at API 30, `BLUETOOTH_ADVERTISE` only with `androidAdvertisingEnabled`, new `androidBleRequired`. The options it owns outright (`neverForLocation`'s flag, `androidBleRequired`, `iOSLazyInit`) follow the config both ways, so turning one off and prebuilding without `--clean` undoes it. Its manifest and Info.plist rules have Jest tests.
- Swift core (operation queue, notification hub, GATT rules) runs its unit tests with `swift test`, also on Linux.
- The package no longer ships test sources (`ios/CoreTests`, `android/src/test`) or local Android build output (`android/build`, `android/.cxx`).
