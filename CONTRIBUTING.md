# Contributing to react-native-ble-nitro (EngineMon fork)

Thank you for your interest in contributing! This repository is EngineMon's fork of [zykeco/react-native-ble-nitro](https://github.com/zykeco/react-native-ble-nitro); contributions to the fork go to [EngineMon/react-native-ble-nitro](https://github.com/EngineMon/react-native-ble-nitro). This document provides guidelines and information for contributors.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Architecture Overview](#architecture-overview)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Code Standards](#code-standards)
- [Submitting Changes](#submitting-changes)
- [Nitro Development](#nitro-development)
- [Native Development](#native-development)
- [Syncing with zykeco upstream](#-syncing-with-zykeco-upstream)

## 🤝 Code of Conduct

This project follows a code of conduct to ensure a welcoming environment for all contributors. Please be respectful, inclusive, and professional in all interactions.

## 🚀 Getting Started

### Prerequisites

- **Node.js** (v22 or higher)
- **npm**
- **React Native development environment** (iOS/Android)
- **Xcode** (for iOS development)
- **Android Studio** (for Android development)
- **TypeScript** knowledge
- **Nitro Modules** familiarity (helpful)

### Repository Structure

```
react-native-ble-nitro/
├── src/                      # TypeScript source code
│   ├── specs/               # Nitro module specifications
│   ├── manager.ts           # BleNitroManager, BleError
│   └── __tests__/           # Jest tests
├── ios/                     # iOS native implementation (Swift)
│   ├── Core/               # Platform-independent core (Foundation only), also a SwiftPM target
│   └── CoreTests/          # Its XCTest unit tests (not part of the pod)
├── android/                 # Android native implementation (Kotlin) and its unit tests
├── scripts/                 # strip-fast-native.mjs, run after every nitrogen run
├── Package.swift            # SwiftPM package for ios/Core and ios/CoreTests
├── plugin/                  # Expo config plugin
├── nitrogen/generated/      # Generated Nitro code (do not edit, not committed)
└── example/                 # Example Expo app
```

## 🛠️ Development Setup

### 1. Fork and Install

```bash
# Fork the repository on GitHub first, then:
git clone https://github.com/YOUR_USERNAME/react-native-ble-nitro.git
cd react-native-ble-nitro
git remote add upstream https://github.com/EngineMon/react-native-ble-nitro.git
npm install
```

### 2. Generate Nitro Code

```bash
npm run nitro-codegen
```

This runs nitrogen (pinned to 0.35.2 in `devDependencies`) to generate the native bindings in `nitrogen/generated/` from the TypeScript specs, then `scripts/strip-fast-native.mjs` (see [The FastNative strip step](#the-fastnative-strip-step)). Don't run `npx nitrogen` on its own: the Android build refuses bindings that weren't stripped.

### 3. Build TypeScript

```bash
npm run build
```

### 4. Run Tests

```bash
npm test
```

## 🏗️ Architecture Overview

### Nitro Modules Foundation

This library is built on [Nitro Modules](https://nitro.margelo.com/), which provides:
- Direct JSI communication (no bridge)
- Type-safe native bindings
- High performance
- Automatic code generation

### Key Components

1. **Nitro Specs** (`src/specs/`): TypeScript interfaces that define the native API
2. **Native Implementation**: Platform-specific BLE implementations
3. **Generated Code** (`nitrogen/generated/`): Auto-generated native bindings

### Data Flow

```
JavaScript/TypeScript (BleNitroManager) → Nitro Specs → Generated Native Code → Platform BLE APIs
```

## 🔄 Development Workflow

### Making Changes

1. **Sync with upstream and create a feature branch**:
   ```bash
   git fetch upstream
   git checkout main
   git merge upstream/main
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** in the appropriate directories:
   - TypeScript changes: `src/`
   - iOS changes: `ios/`
   - Android changes: `android/`
   - Tests: `src/__tests__/`

3. **Regenerate Nitro code** if you modified specs:
   ```bash
   npm run nitro-codegen
   ```

4. **Build and test**:
   ```bash
   npm run build
   npm test
   npm run lint
   ```

5. **Test with example app** (if available):
   ```bash
   cd example
   npm install
   npx expo run:ios  # or run:android
   ```

### Important Notes

- **Never edit `nitrogen/generated/`** - these files are auto-generated
- **Always run `npm run nitro-codegen`** after modifying Nitro specs
- **Add tests** for new functionality

## 🧪 Testing

### JS tests (Jest)

```bash
# Run all JS tests: the JS layer and the Expo plugin
npm test

# Run a specific test file
npm test -- src/__tests__/index.test.ts
```

- `src/__tests__/` tests the JS layer (`src/`) against a mocked native object; `src/__tests__/index.test.ts` shows how the native factory is mocked.
- `plugin/__tests__/` tests the Expo plugin's manifest and Info.plist rules through the pure functions `applyAndroidManifest` and `applyInfoPlist` in `plugin/src/withBleNitro.ts`, without running a prebuild. The folder sits outside `plugin/src`, so the plugin build doesn't compile it.

### Swift core tests (SwiftPM)

`ios/Core` is the platform-independent part of the iOS implementation: the operation queue, the notification hub, the callback wrappers, ID and observer bookkeeping, and the GATT rules (property and length checks, connect timeout, MTU range). It uses Foundation only, so `Package.swift` builds it as a SwiftPM package and runs its tests without Xcode, CocoaPods, a simulator or a device:

```bash
# In the repository root; works on macOS and on Linux with a Swift toolchain
swift test
```

The tests are in `ios/CoreTests`. The pod compiles `ios/Core` together with the CoreBluetooth code and leaves `ios/CoreTests` out (`BleNitro.podspec`).

### Kotlin unit tests

The Android core has the same pure classes under the same names (`GattOperationQueue`, `NotificationHub`, `GattRules`, `ObserverSet`, `IdSource`, the callback wrappers), plus `BleErrors` and `ScanStartThrottle`, tested as JVM unit tests in `android/src/test/`. Kotlin and Swift cover the same cases, so a behavior change goes into both. Run them through the example app's Gradle project:

```bash
cd example/android && ./gradlew :react-native-ble-nitro:testDebugUnitTest
```

### The FastNative strip step

nitrogen 0.35 marks the JNI method behind every generated Kotlin callback class (`Func_*.kt`, `invoke_cxx`) `@FastNative`. A C++ callback that waits on a lock whose holder calls into Java during a garbage collection then hangs the app, because the collector can't suspend a thread inside a `@FastNative` method. `scripts/strip-fast-native.mjs` removes the annotation and its import from `nitrogen/generated/android`; `npm run nitro-codegen` runs it after nitrogen. The script fails without writing anything when nitrogen's output doesn't look as expected (no `Func_*.kt`, or a `FastNative` it doesn't know how to remove), so a nitrogen upgrade breaks it loudly.

The Android build checks the result: the Gradle task `checkGeneratedBindingsHaveNoFastNative` fails while any generated Kotlin file of this library still mentions `FastNative` (the script's own rule, so the fully qualified `@dalvik.annotation.optimization.FastNative` form fails too), and also when `nitrogen/generated/android` is missing. Any other script that runs nitrogen for this library (e.g. an app that vendors it) must run the strip step too:

```bash
node scripts/strip-fast-native.mjs
```

When upgrading nitrogen, regenerate, check that the script still finds the annotation, and update the pin in `package.json` and the `react-native-nitro-modules` peer range together: the generated code depends on the nitrogen minor.

### On-device testing

The example app (`example/`) against real peripherals, on iOS and Android.

### Writing Tests

- Test both success and error scenarios, including the `BleErrorCode` of each failure
- A change to the pure core gets the same test in Kotlin and Swift

## 📏 Code Standards

### TypeScript

- Use **strict mode** TypeScript
- Prefer **interfaces** over types when possible
- Use **explicit return types** for public methods
- Follow **naming conventions**:
  - `PascalCase` for classes, interfaces, enums
  - `camelCase` for variables, functions, methods
  - `UPPER_SNAKE_CASE` for constants

### Code Style

- Use **Prettier** for formatting
- Use **ESLint** for linting
- **2 spaces** indentation
- **Single quotes** for strings
- **Semicolons** required

### Documentation

- Use **JSDoc** for public APIs
- Include **@param** and **@returns** tags
- Add **@example** for complex functions
- Keep comments up-to-date

### Example

```typescript
/**
 * Connects to a BLE device
 * 
 * @param deviceId - The device identifier
 * @param options - Connection options
 * @returns Promise that resolves to the connected device
 * 
 * @example
 * ```typescript
 * const device = await manager.connectToDevice('device-id', {
 *   autoConnect: true,
 *   timeout: 5000
 * });
 * ```
 */
async connectToDevice(
  deviceId: string, 
  options?: ConnectionOptions
): Promise<Device> {
  // Implementation
}
```

## 📝 Submitting Changes

### Pull Request Process

1. **Fork the repository** and create your branch from `main` (see Development Setup above)
2. **Make your changes** following the guidelines above
3. **Add tests** for new functionality
4. **Update documentation** if needed
5. **Run the full test suite** and ensure it passes
6. **Run linting** and fix any issues
7. **Create a pull request** with a clear description

### Pull Request Template

```markdown
## Description
Brief description of the changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Tests pass locally
- [ ] Added tests for new functionality
- [ ] Tested on iOS
- [ ] Tested on Android

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No breaking changes (or documented)
```

### Commit Message Format

Use conventional commits:

```
type(scope): description

feat(ios): add MTU negotiation support
fix(android): resolve scanning permission issue
docs(readme): update installation instructions
test(manager): add connection timeout tests
```

## ⚡ Nitro Development

### Understanding Nitro Specs

Nitro specs define the interface between JavaScript and native code. `src/specs/NativeBleNitro.nitro.ts` is the native contract; its doc comments define threading, ordering and completion rules that both platforms and C++ consumers rely on:

```typescript
// src/specs/NativeBleNitro.nitro.ts
export interface NativeBleNitro extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  readCharacteristic(deviceId: string, serviceId: string, characteristicId: string, callback: ReadCharacteristicCallback): void;
  // ...
}
```

### Nitro Constraints

- **Numeric enums only** (no string enums)
- **No index signatures** (`{ [key: string]: value }`)
- **No inline union types**
- **Structured data** instead of flexible objects
- **Specific callback signatures**

### Regenerating Code

Always run after spec changes:

```bash
npm run nitro-codegen
```

This updates:
- `nitrogen/generated/ios/` - Swift bindings
- `nitrogen/generated/android/` - Kotlin bindings
- `nitrogen/generated/shared/` - C++ core

## 📱 Native Development

Both platforms have the same layers under the same names, so a fix on one side has an obvious place on the other. Android sources are in `android/src/main/java/com/margelo/nitro/co/zyke/ble/`, iOS sources in `ios/`.

| Layer | Responsibility | Android | iOS |
|---|---|---|---|
| Facade | Implements the spec: parses and copies inputs on the caller's thread, allocates ids, wraps every user callback once through the `CallbackGate` (silent listeners and `BluetoothManagerDestroyed` completions after `destroy()`) | `BleNitroBleManager.kt`, `CallbackGate.kt` | `BleNitroBleManager.swift`, `CallbackGate.swift` |
| Manager core | The adapter or central, the links, observers, scanning, `destroy()`; every asynchronous call enters through one entry point that fails it once `destroy()` was called | `BleCore.kt`, `BleScanner.kt`, `BleDevices.kt`, `GattUuid.kt`; Android only: `ScanPreconditions.kt`, `BluetoothEnableRequest.kt` | `BleCore.swift`, `BleScanner.swift`, `BleDevices.swift`, `GattUuid.swift`, `BleNitroConversions.swift`; iOS only: `PoweredOnWaiters.swift`, `StateRestoration.swift`, `BleCentralManagerDelegate.swift` |
| Link | One device's connect and disconnect state machine and its single close funnel | `GattConnection.kt` | `PeripheralLink.swift` |
| Session | One link-up: operation queue, notification hub, database generation, MTU, characteristic lookup, one class per operation | `GattSession.kt`, `LinkCallback.kt` | `GattSession.swift`, `GattSessionOperations.swift`, `DispatchOperationTimer.swift` |
| Errors | Every `BleError` the library builds, with the same builder names on both platforms | `BleErrors.kt` | `BleErrors.swift` |
| Pure core | `Callbacks`, `CoreLog`, `GattOperationQueue`, `GattRules`, `IdSource`, `NotificationHub`, `ObserverSet`: no OS or Nitro imports, the same names and test cases on both platforms | the same names in `android/src/main/.../ble/`, tests in `android/src/test/` | `ios/Core/`, tests in `ios/CoreTests/` |

`BleNitroLifecycle.kt` (Android only) destroys every manager when React Native tears down a JS runtime.

On both platforms:

- Everything runs on the manager's executor: Android's HandlerThread, which also receives every `BluetoothGattCallback`, and iOS's `CBCentralManager` serial DispatchQueue. Never touch BLE state from another thread.
- Every operation completes its callback exactly once, with a result or a `BleError`.
- Comments state the requirement a piece of code meets. Cite this library's contract as `NativeBleNitro.nitro.ts, "<section>"` and the Bluetooth specification as `Bluetooth Core Specification Vol N Part X §Y`.

## 🔀 Syncing with zykeco upstream

Maintainers bring upstream changes into the fork by merging, never by rebasing: consumers pin commits of `main`, and a rebase would orphan them.

```bash
git remote add zykeco https://github.com/zykeco/react-native-ble-nitro.git
git config remote.zykeco.tagOpt --no-tags   # upstream's v1.x tags stay out of the fork
git fetch zykeco
git checkout main
git merge zykeco/main
```

Keep the native identifiers (pod `BleNitro`, Kotlin package `com.margelo.nitro.co.zyke.ble`, C++ namespace) unchanged so upstream changes keep merging.

## 🔧 Troubleshooting

### Common Issues

1. **Nitro codegen fails**: Check TypeScript specs for Nitro constraints
2. **Tests fail**: Ensure mocks are properly configured
3. **Build errors**: Run `npm run clean` and rebuild
4. **Permission issues**: Check Android/iOS permission configurations

### Getting Help

- **GitHub Issues**: [EngineMon/react-native-ble-nitro](https://github.com/EngineMon/react-native-ble-nitro/issues) for bugs, questions and feature requests
- **Nitro Documentation**: https://nitro.margelo.com/

## 📄 License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to react-native-ble-nitro! 🚀