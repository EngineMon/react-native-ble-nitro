# Releasing react-native-ble-nitro (EngineMon fork)

This fork is **not published to npm**: the name `react-native-ble-nitro` on npm belongs to upstream ([zykeco/react-native-ble-nitro](https://github.com/zykeco/react-native-ble-nitro)). A release is a git tag on `main` plus a GitHub release. Consumers install a tag from GitHub (`npm install github:EngineMon/react-native-ble-nitro#vX.Y.Z`), which builds the package on install, or pin a commit as a git submodule.

`main` is never rebased or force-pushed, and tags are never moved: consumers pin both.

## 📋 Pre-Release Checklist

### 1. Code Quality & Testing
- [ ] All JS tests pass: `npm test`
- [ ] Linting passes: `npm run lint`
- [ ] TypeScript compilation successful: `npm run typecheck`
- [ ] Nitro code generation works: `npx nitro-codegen`
- [ ] The full build works: `npm run build`
- [ ] Kotlin unit tests pass: `cd example/android && ./gradlew :react-native-ble-nitro:testDebugUnitTest`
- [ ] The example app works on a real iOS and Android device

### 2. Documentation Review
- [ ] README.md is up-to-date, including the migration section for breaking changes
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
