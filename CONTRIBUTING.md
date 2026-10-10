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
├── android/                 # Android native implementation (Kotlin) and its unit tests
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
npx nitro-codegen
```

This generates native bindings in `nitrogen/generated/` from the TypeScript specs.

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
   npx nitro-codegen
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
- **Always run `nitro-codegen`** after modifying Nitro specs
- **Add tests** for new functionality

## 🧪 Testing

### Running Tests

```bash
# Run all JS tests
npm test

# Run a specific test file
npm test -- src/__tests__/index.test.ts

# Kotlin unit tests (GattOperationQueue, BleErrors, ScanStartThrottle), through the example app's Gradle project
cd example/android && ./gradlew :react-native-ble-nitro:testDebugUnitTest
```

### Test Categories

1. **JS tests** (`src/__tests__/`): `BleNitroManager` against a mocked native object
2. **Kotlin unit tests** (`android/src/test/`): the Android operation queue, error mapping and scan throttling
3. **On-device testing**: the example app (`example/`) against real peripherals

### Writing Tests

- Use **Jest**; `src/__tests__/index.test.ts` shows how the native factory is mocked
- Test both success and error scenarios, including the `BleErrorCode` of each failure

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
npx nitro-codegen
```

This updates:
- `nitrogen/generated/ios/` - Swift bindings
- `nitrogen/generated/android/` - Kotlin bindings
- `nitrogen/generated/shared/` - C++ core

## 📱 Native Development

### iOS Development (Swift)

- `ios/BleNitroBleManager.swift` implements the spec; `ios/BlePeripheralDelegate.swift` holds per-peripheral state and its operation queue
- Everything runs on the `CBCentralManager`'s dedicated serial DispatchQueue; never touch BLE state from another thread
- Every operation completes its callback exactly once, with a result or a `BleError`

### Android Development (Kotlin)

- Sources are in `android/src/main/java/com/margelo/nitro/co/zyke/ble/`: `BleNitroBleManager.kt` implements the spec, `GattConnection.kt` owns one link, `GattOperationQueue.kt` serializes its GATT operations
- Everything runs on the manager's HandlerThread, which also receives every `BluetoothGattCallback`
- Every operation completes its callback exactly once, with a result or a `BleError`

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