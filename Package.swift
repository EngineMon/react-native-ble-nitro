// swift-tools-version:5.9
//
// The platform-independent part of the iOS implementation (ios/Core: operation queue,
// notification hub, callback wrappers, GATT rules) and its unit tests (ios/CoreTests),
// as a SwiftPM package so `swift test` runs them on macOS or Linux without Xcode,
// CocoaPods, a simulator or a device. ios/Core uses Foundation only, no CoreBluetooth
// or Nitro, which is what makes that possible.
//
// The app doesn't use this package: CocoaPods compiles ios/Core into the BleNitro pod
// together with the CoreBluetooth glue, as one module (BleNitro.podspec, which also
// keeps ios/CoreTests out of the pod).
//
// Swift 5 language mode, the mode the pod is compiled in (the podspec sets no
// swift_version). The core also compiles in Swift 6 mode with strict concurrency.
import PackageDescription

let package = Package(
    name: "BleNitroCore",
    targets: [
        .target(name: "BleNitroCore", path: "ios/Core"),
        .testTarget(name: "BleNitroCoreTests", dependencies: ["BleNitroCore"], path: "ios/CoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
