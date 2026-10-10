# react-native-ble-nitro (EngineMon fork)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> [!IMPORTANT]
> This is [EngineMon](https://github.com/EngineMon)'s fork of [zykeco/react-native-ble-nitro](https://github.com/zykeco/react-native-ble-nitro), branched from upstream 1.15.1. It is **not published to npm**: `npm install react-native-ble-nitro` installs upstream 1.x, whose API differs from this README. Install it from GitHub ([Installation](#installation)).

A high-performance React Native BLE library built on [Nitro Modules](https://nitro.margelo.com/).

Originally developed for [Zyke Band](https://zykeband.com?utm_source=github&utm_medium=readme&utm_campaign=opensource) - a fitness and health tracker created by a small team.

## 🍴 Why this fork

Apps that stream data from a peripheral over BLE and process it in native code, off the JS thread, need a BLE layer that stays correct under sustained load and that native code can drive directly. This fork is that layer:

- **Per-device operation queues**: one GATT operation at a time per device, in call order, each with a 30 s timeout. Operations never overlap on Android's single-outstanding-operation GATT.
- **Flow-controlled writes without response**: a write resolves when the OS accepted it, so a burst can't overflow the OS buffers and silently drop packets.
- **Link-loss handling**: when a link drops or the manager is destroyed, every pending operation fails instead of hanging.
- **A dedicated BLE thread per manager** on both platforms, with callbacks delivered in OS order.
- **Typed errors**: every failure is a `BleError` with a code numbered like react-native-ble-plx's, plus the platform status.
- **A C++ API**: another native module can use the same manager from C++, e.g. to consume a notification stream without a JS hop per notification.
- **Shared subscriptions**: any number of subscribers per characteristic, each with its own id and end callback, so JS and C++ on one manager never silence each other.
- **Strict GATT rules**: property and length checks before anything reaches the device, a timed-out operation takes its link down, and Service Changed ends the affected subscriptions instead of leaving them silently dead.

3.0 changes the API; see [Migrating from 2.x to 3.0](#migrating-from-2x-to-30). For 1.x code, read [Migrating from 1.x to 2.0](#-migrating-from-1x-to-20) first.

### Relationship to upstream

- `main` is upstream's history plus our commits. Upstream changes come in by merging `upstream/main`; `main` is never rebased or force-pushed, because consumers pin its commits.
- The package name, the Expo plugin name and the native identifiers (pod `BleNitro`, `libBleNitro.so`, Kotlin package `com.margelo.nitro.co.zyke.ble`, C++ namespace `margelo::nitro::co::zyke::ble`) are upstream's, so upstream changes keep merging. As a consequence, this fork and upstream's package can't be installed in the same app.
- Bugs in this fork belong in [this repository's issues](https://github.com/EngineMon/react-native-ble-nitro/issues), not upstream's.

## ✨ Features

- 🚀 **High Performance**: Built on Nitro Modules with JSI; each characteristic value arrives as an `ArrayBuffer` of its own
- 📱 **iOS Support**: Complete iOS implementation with Swift and Core Bluetooth
- 🤖 **Android Support**: Complete Android implementation with Kotlin and Android BLE APIs
- 🧵 **Off the main thread**: each manager runs on its own thread (Android HandlerThread, iOS serial DispatchQueue)
- 🚦 **Reliable GATT**: operations on a device run one at a time in call order, time out after 30 s (taking the link down), and fail when the link drops
- 🌊 **Flow control**: a write without response resolves when the OS accepted it, so awaiting each write paces a burst
- ❗ **Typed errors**: every failure is a `BleError` with a numeric code (the same numbers as react-native-ble-plx) and the platform status
- 🧩 **C++ API**: other native modules can drive the manager from C++, e.g. to consume notifications without touching the JS thread
- 🎯 **Type-Safe**: Full TypeScript support with comprehensive type definitions
- 📡 **Advertisement Data**: Extract advertised service data and manufacturer data from scan results
- 🔧 **Expo Ready**: Built-in Expo config plugin for easy setup
- 🏗️ **New Architecture**: Full support for React Native's new architecture

## 🚀 Quick Start

### Installation

Install from GitHub, pinned to a release tag:

```bash
npm install --allow-git=root react-native-nitro-modules github:EngineMon/react-native-ble-nitro#v3.0.0
```

npm 12 refuses git dependencies unless allowed: pass `--allow-git=root`, or put `allow-git=root` in your project's `.npmrc` so later installs keep working. Older npm versions don't need it.

npm builds the package on install through its `prepare` script (Nitro bindings, TypeScript and the Expo plugin), so the install must run scripts (not `--ignore-scripts`). Imports and the Expo plugin keep the name `react-native-ble-nitro`.

The app needs `react-native-nitro-modules` 0.35 (the peer range is `~0.35.0`). The generated C++ and JNI bindings depend on the nitrogen minor version they were generated with, so a different Nitro minor needs a new release of this library, not just a looser range.

### Expo Setup

Add the plugin to your `app.json` or `app.config.js`:

```json
{
  "expo": {
    "plugins": [
      [
        "react-native-ble-nitro",
        {
          "neverForLocation": true,
          "modes": ["central"],
          "bluetoothAlwaysPermission": "Allow $(PRODUCT_NAME) to connect to bluetooth devices"
        }
      ]
    ]
  }
}
```

See [Expo Plugin Options](#expo-plugin-options) for what each option does. Then prebuild and run:

```bash
npx expo prebuild
npx expo run:android
# or
npx expo run:ios
```

### React Native CLI Setup

For bare React Native projects, the library auto-links. Just run:

```bash
npx pod-install # iOS only
```

## 📖 Usage

### Basic Setup

```typescript
import { BleNitro, BleNitroManager, BLEState, AndroidScanMode, AndroidConnectionPriority, type BLEDevice } from 'react-native-ble-nitro';

// Get the singleton instance
const ble = BleNitro.instance();

// Use custom manager instance (e.g. for iOS state restoration)
// It is recommended to create this instance in an extra file seperated from other BLE business logic for better fast-refresh support
const ble = new BleNitroManager({
  restoreIdentifier: 'my-unique-identifier',
  onRestoredState: (peripherals) => {
    console.log('Restored peripherals:', peripherals);
  },
});

// Release the manager (scans, links, OS resources) when you no longer need it.
// Don't destroy the shared BleNitro.instance().
ble.destroy();
```

After `destroy()` the manager is unusable: every method throws or rejects with `BluetoothManagerDestroyed`, except those that only release something (`stopScan()`, `Subscription.remove()`, `AsyncSubscription.remove()`, `destroy()`), which do nothing. From the moment `destroy()` is called no listener fires: no values, no `onEnded`, no disconnect callback, no connection events, no state changes, no scan results, no restored state. Links close silently. Every completion that fires after that fails once with `BluetoothManagerDestroyed`, also one whose answer from the device was already on its way, and also one whose success the native side had already sent before `destroy()` (it reaches the JS thread later; the JS layer rejects it), so a pending promise never resolves after `destroy()`.

On Android a JS reload destroys every manager the old JS runtime created (closing their links, stopping their scans), also ones a native module still holds. As with any `destroy()`, no listener fires; pending completions fail with `BluetoothManagerDestroyed`, but the JS ones are dropped because the old JS thread is already gone, while C++ ones still run. On iOS a manager is destroyed when its last JS or C++ reference goes away, which a reload causes once the old runtime is collected; a native module holding `nativeObject` keeps it alive until it lets go.

### Complete API Reference

#### 🔌 Bluetooth State Management

```typescript
// Check if Bluetooth is enabled
const isEnabled = ble.isBluetoothEnabled();

// Get current Bluetooth state
const state = ble.state();
// Returns: BLEState.PoweredOn, BLEState.PoweredOff, etc.

// Android: asks the user to turn Bluetooth on. Resolves once they did (at once when it is on),
// rejects with OperationCancelled when they declined, or BluetoothStateChangeFailed when there
// is no activity to ask from. iOS doesn't let apps turn Bluetooth on: always BluetoothStateChangeFailed.
await ble.requestBluetoothEnable();

// Subscribe to state changes. Any number of subscriptions may exist, each registered natively
// on its own, so one that throws doesn't keep the change from the others.
const subscription = ble.subscribeToStateChange((state) => {
  console.log('Bluetooth state changed:', state);
}, true); // true = also call it with the current state before returning

// Removes only this subscription; a second call does nothing
subscription.remove();

// Open Bluetooth settings
await ble.openSettings();

// Explicitly initialize BLE on iOS (optional, iOS only)
// Useful to trigger the Bluetooth permission dialog at a specific moment
// when using lazy iOS initialization.
ble.iosLazyInit();
```

iOS reports `Unknown` until CoreBluetooth delivered its first state (right after the manager is created, or while the permission prompt is open). A call that needs Bluetooth on (scan, connect) made in that window waits for the first state, then runs, or fails with the error of the state it got (`BluetoothPoweredOff`, `BluetoothUnauthorized`, ...). A connect's `timeoutMs` counts from when it actually starts.

#### 🔍 Device Scanning

```typescript
// Start scanning for devices. Starting a scan stops the previous one.
ble.startScan({
  serviceUUIDs: ['180d'], // Optional: filter by service UUIDs
  rssiThreshold: -80,     // Optional: minimum signal strength (default: none)
  allowDuplicates: false, // Optional: report every advertisement, not only the first (default false)
  androidScanMode: AndroidScanMode.Balanced // Optional: Android scan mode (default Balanced)
}, (device) => {
  console.log('Discovered device:', device);

  // Advertised service data, keyed by service UUID (byte arrays)
  device.serviceData.services.forEach(({ uuid, data }) => {
    console.log(`Service data for ${uuid}:`, data);
  });

  // Advertised manufacturer data, keyed by company identifier (byte arrays)
  device.manufacturerData.companyIdentifiers.forEach(({ id, data }) => {
    console.log(`Manufacturer data for ${id}:`, data);
  });
}, (error) => {
  // The scan failed to start or stopped by itself (a BleError, e.g. ScanStartFailed
  // with the Android scan error code in error.nativeStatus). The scan is over.
  // Without this callback, the failure is thrown (it reaches the global error handler).
  console.error('Scan error:', error.errorCode, error.message);
});

// Stop scanning. No scan callback is called after this returns.
ble.stopScan();

// Check if currently scanning
const isScanning = ble.isScanning();

// Get already connected devices
const connectedDevices = ble.getConnectedDevices(['180d']); // Optional: filter by service UUIDs
```

Notes on scanning:

- `startScan()` always ends the running scan before it starts the new one, except when the filter is invalid (a malformed UUID): that throws `InvalidIdentifiers` first and leaves the running scan untouched. A start that then fails before reaching the OS (Android's limit of scan starts per 30 s) reports to the new scan's `onError`; the previous scan is already over. Only native (C++) callers of `startScan` (`src/specs/NativeBleNitro.nitro.ts`) keep a running scan when the new start fails that way.
- `device.name` is the name the device advertises, falling back to the name the OS has cached for it, and `''` when neither exists.
- Filter by service when you can. Android pauses scans without a filter while the screen is off ("For unfiltered scans, scanning is stopped on screen off to save power", `BluetoothLeScanner.startScan`), and iOS delivers scan results to a background app only for scans for specific services.
- iOS with `rssiThreshold`: the scan runs with duplicates on so a device that comes closer is noticed, and each device is reported once, the first time it passes the threshold (every time with `allowDuplicates`). An RSSI of 127 ("not available") never passes.
- `isConnected` in a result tells whether this manager's link to the device is up.

`getConnectedDevices(services)` differs per platform. Devices with `isConnected: false` are connected to the system (e.g. by another app) and need `connect()` first.

| | Android | iOS |
|---|---|---|
| This manager's links | Those whose discovered services include one of `services` (all when empty) | All |
| Other devices connected to the system | Only when `services` is empty (Android can't tell their services); left out without the `BLUETOOTH_CONNECT` permission | Those offering one of `services` (`retrieveConnectedPeripherals`); none when empty |

#### 🔗 Device Connection

```typescript
// Connect to a device with disconnect event handling. Resolves with the device's canonical id
// (uppercase MAC address on Android, uppercase peripheral UUID on iOS), the form every callback
// and event carries, whatever letter case you passed.
const deviceId = await ble.connect(deviceId, {
  autoConnectAndroid: false, // Optional: Android connectGatt autoConnect (default false)
  refreshGattAndroid: true,  // Optional: Android: clear the OS GATT cache right after connecting (default false)
  timeoutMs: 10_000,         // Optional: fail with OperationTimedOut and cancel the link attempt
}, (deviceId, interrupted, error) => {
  if (interrupted) {
    // The device or the OS dropped the link (DeviceDisconnected + status), or an
    // operation on it timed out and took it down (OperationTimedOut)
    console.log('Connection interrupted:', error);
  } else {
    // disconnect(); not called after destroy()
    console.log('Disconnected intentionally');
  }
});

// Connect without options or disconnect callback
const deviceId = await ble.connect(deviceId);

// Connecting to a device that is already connected (e.g. restored by iOS) resolves.
// A given disconnect callback replaces the installed one; without one the installed one stays.

// You can also use findAndConnect to scan and connect in one step, e.g. to reconnect after an
// app restart or an unexpected disconnect. Resolves with the canonical id, like connect().
const deviceId = await ble.findAndConnect(deviceId, {
  scanTimeout: 4000, // default 5000ms; rejects with DeviceNotFound when the device isn't found
  serviceUUIDs: ['180d'], // Optional: scan only for these services (see the scanning notes)
  refreshGattAndroid: true, // any connect() option
  // Optional: called with the scan result as the connect starts, from the scan's callback.
  // If it throws, the error reaches the global error handler and the connect goes on.
  onFound: (device) => console.log('Found', device.name),
  onDisconnect: (deviceId, interrupted, error) => {
    if (interrupted) {
      console.log('Connection interrupted:', error);
    } else {
      console.log('Disconnected intentionally');
    }
  }
});

// Disconnect from a device, or cancel a pending connect (which then rejects with
// OperationCancelled). Resolves once the link is down.
await ble.disconnect(deviceId);

// Check connection status
const isConnected = ble.isConnected(deviceId);

// MTU (an integer from 23 to 517, else DeviceMTUChangeFailed): resolves with the ATT MTU in
// effect. Android negotiates the requested value; iOS negotiates by itself and returns its MTU.
const mtu = await ble.requestMTU(deviceId, 517);

// The ATT MTU in effect right now, or undefined when the device isn't connected
const current = ble.getMtu(deviceId);
// The longest write without response; writes with response carry up to 512 bytes
if (current !== undefined) {
  const maxWriteWithoutResponse = Math.min(current - 3, 512);
}

// Request a connection priority while connected. Android only. iOS has no connection priority:
// resolves while the link is up, rejects with DeviceNotConnected otherwise.
// Resolves when Android accepted the request; the change itself applies asynchronously.
await ble.requestConnectionPriority(deviceId, AndroidConnectionPriority.High);

// AndroidConnectionPriority options:
//   AndroidConnectionPriority.High      → lower latency, higher power usage
//   AndroidConnectionPriority.Balanced  → default balanced connection interval
//   AndroidConnectionPriority.LowPower  → higher latency, lower power usage

// Read RSSI value
const rssi = await ble.readRSSI(deviceId);
console.log('Current RSSI:', rssi);
```

Notes on connecting:

- While another `connect()` to the device is pending, `connect()` rejects with `DeviceAlreadyConnected` and the pending one goes on.
- `timeoutMs`: absent or `Infinity` lets the OS decide (Android about 30 s, iOS never). `NaN`, 0 or a negative value rejects with `OperationStartFailed`.
- iOS keeps some connection attempts pending by itself, e.g. one for a peripheral it restored. `connect()` takes such an attempt over instead of starting a new one, and its `timeoutMs` then rejects only the call: it never cancels the OS's attempt, which wasn't the call's to cancel. When such an attempt connects while no `connect()` waits, the manager keeps the link and reports `Connected` (see [Connection events](#connection-events)); the next `connect()` resolves at once.
- A link being taken down after an operation timed out is connected anew once it is down.
- `refreshGattAndroid` calls `BluetoothGatt.refresh()`, a hidden non-SDK method, by reflection. It runs only when you ask for it, and a failure is logged and tolerated (the connect still succeeds, possibly with a stale GATT cache). Android may block non-SDK interfaces in a future release.
- Android connects through `BluetoothAdapter.getRemoteDevice(address)`, which doesn't carry the LE address type. Android uses the type it learned from a recent scan; for a device using a random address it hasn't seen, scan first (`findAndConnect()` does).
- Android 14 and later negotiate an MTU of 517 by themselves on the first exchange of a connection and ignore later requests. `requestMTU()` then resolves with the current MTU, at once or after 3 s without an answer. `getMtu()` follows every exchange, including ones the device starts.
- iOS has no connection priority: `requestConnectionPriority()` resolves while the link is up and rejects with `DeviceNotConnected` otherwise.

#### Connection events

```typescript
import { ConnectionEventType } from 'react-native-ble-nitro';

const events = ble.onConnectionEvent(({ deviceId, type, interrupted, error }) => {
  switch (type) {
    case ConnectionEventType.Connected:       // a link of this manager came up
    case ConnectionEventType.Disconnected:     // it went down; interrupted/error as in its disconnect callback
    case ConnectionEventType.ServicesChanged: // the device changed its GATT database
  }
});
events.remove();
```

- `Connected` fires once per link, right before the `connect()` that brought it up (or adopted it) resolves. On iOS it also fires for an OS-pending attempt that connected while no `connect()` waited.
- `Disconnected` fires only for a link that reported `Connected`, right after its disconnect callback.
- `ServicesChanged`: see [Service Changed](#service-changed).
- `deviceId` is canonical: the uppercase MAC address on Android, the uppercase peripheral UUID on iOS. Methods accept ids in any letter case.

#### 🔧 Service Discovery

```typescript
// Discover all services and their characteristics (both platforms). Needed once per link,
// and again after ServicesChanged. Android: a failed discovery ends the link's
// subscriptions (see below).
await ble.discoverServices(deviceId);

// Discover services and get their UUIDs
const services = await ble.getServices(deviceId);
// Returns: ['0000180d-0000-1000-8000-00805f9b34fb', '0000180f-0000-1000-8000-00805f9b34fb', ...]
// Always returns full lowercase 128-bit UUIDs

// Discover, then list the services with their characteristics
const servicesWithCharacteristics = await ble.getServicesWithCharacteristics(deviceId);
// Returns: [{ uuid: '0000180d-0000-1000-8000-00805f9b34fb', characteristics: ['00002a37-0000-1000-8000-00805f9b34fb', ...] }, ...]

// Characteristics of a discovered service
const characteristics = ble.getCharacteristics(deviceId, '180d');
// Returns: ['00002a37-0000-1000-8000-00805f9b34fb', '00002a38-0000-1000-8000-00805f9b34fb', ...]

// The properties a discovered characteristic declares; undefined when the lookup fails
const props = ble.getCharacteristicProperties(deviceId, '180d', '2a37');
// { read: false, write: false, writeWithoutResponse: false, notify: true, indicate: false }
```

Characteristic operations look the characteristic up when they start, so one queued behind `discoverServices()` sees its result. The lookup fails, in this order, with:

| Code | When |
|---|---|
| `InvalidIdentifiers` (5) | A device id or UUID doesn't parse |
| `DeviceNotConnected` (205) | This manager has no link up to the device |
| `ServicesNotDiscovered` (303) | No discovery completed on this link, or the device's services changed since |
| `ServiceNotFound` (302) | The device has no such service |
| `CharacteristicsNotDiscovered` (405) | The service's characteristics aren't discovered |
| `CharacteristicNotFound` (404) | The service has no such characteristic |

Then the characteristic's declared properties must allow the operation: a read needs `read`, a write with response needs `write`, a write without response needs `writeWithoutResponse` (neither write type stands in for the other), a subscription needs `notify` or `indicate`. Otherwise the operation fails with its own code (read 402, write 401, subscribe 403), without `nativeStatus`, and nothing is sent.

#### 📖 Reading Characteristics

```typescript
// Read a characteristic value
const data = await ble.readCharacteristic(deviceId, serviceUUID, characteristicUUID);
// Returns: ArrayBuffer

// Example: Reading battery level
const batteryData = await ble.readCharacteristic(deviceId, '180f', '2a19');
const batteryLevel = new Uint8Array(batteryData)[0]; // First byte is battery percentage
console.log('Battery level:', batteryLevel + '%');
```

iOS limit: CoreBluetooth reports read responses and notifications through the same delegate callback (`peripheral(_:didUpdateValueFor:error:)`), so a read of a characteristic that is notifying resolves with whichever of the two arrives first. Every value still reaches the subscribers.

#### ✍️ Writing Characteristics

```typescript
// Write to a characteristic with response.
// data is an ArrayBuffer (all of it), any ArrayBufferView such as a Uint8Array or a Buffer
// (exactly the bytes it views), or a number[] of integers from 0 to 255.
const result = await ble.writeCharacteristic(
  deviceId,
  serviceUUID,
  characteristicUUID,
  new Uint8Array([0x01, 0x02, 0x03]).buffer,
  true // withResponse = true (default)
);
// result is an ArrayBuffer with the bytes written

// Write without response: resolves when the OS accepted the write for sending
await ble.writeCharacteristic(deviceId, serviceUUID, characteristicUUID, [0x01, 0x02, 0x03], false);
```

The bytes are copied during the call, so you may reuse or change the buffer as soon as `writeCharacteristic` returns. Anything else as `data`, or an array entry outside 0 to 255, rejects with `CharacteristicInvalidDataFormat` and writes nothing (a `Uint8Array` would silently wrap 256 to 0).

Write limits, checked before anything is sent (longer data rejects with `CharacteristicWriteFailed`):

- With response: 512 bytes, the longest attribute value (Bluetooth Core Specification Vol 3 Part F §3.2.9).
- Without response: `min(getMtu() - 3, 512)`, what one Write Command carries (Bluetooth Core Specification Vol 3 Part G §4.9.1).

Android would otherwise send a longer write cut short without telling you, or throw from Android 15 when it is over 512 bytes. See [Flow control](#flow-control-writes-without-response) for bursts.

#### 📡 Characteristic Notifications

```typescript
// Resolves once notifications are on (CCCD written and acknowledged)
const subscription = await ble.subscribeToCharacteristic(
  deviceId,
  serviceUUID,
  characteristicUUID,
  (data) => {
    // data: a copy of the value in a new ArrayBuffer
    console.log('Received notification:', new Uint8Array(data));
  },
  (error) => {
    // Optional onEnded: the subscription ended without remove(), see below
    console.log('Subscription ended:', error.errorCode);
  }
);

// Ends this subscription. No value is delivered after remove() is called.
await subscription.remove();

// Whether an active subscription of this manager exists on the characteristic
const isSubscribed = ble.isSubscribedToCharacteristic(deviceId, serviceUUID, characteristicUUID);
// Returns false for disconnected or unknown devices without throwing
```

Subscriptions add up. Any number may exist for one characteristic, each with its own callbacks, also from C++ code sharing the manager. The manager writes the CCCD (Client Characteristic Configuration descriptor) on with the first subscriber of a link and off after the last one, and only when its state has to change, so `remove()` ends only its own subscription and never silences another one. A characteristic that only indicates gets indications.

- `onValue` may run before the promise resolves: a device may notify as soon as it got the CCCD write. It never runs after the promise rejected, after `remove()`, after `onEnded`, or after `destroy()`.
- The promise rejects with a lookup or property error (see [Service Discovery](#-service-discovery)), `CharacteristicNotifyChangeFailed` (403) with `nativeStatus` when the CCCD write failed, or what would otherwise have ended the subscription. A rejected subscription is over.
- `remove()` stops the values at once and resolves when the native side released the subscription. When turning notifications off fails it rejects with `CharacteristicNotifyChangeFailed`, but the subscription is ended either way. Once the subscription ended, `remove()` resolves without doing anything. Every call to `remove()` returns the same promise, so a second caller gets the outcome of the first (including a `CharacteristicNotifyChangeFailed`).
- `onEnded` fires once when the subscription ends without `remove()`: the link went down or anyone called `disconnect()` (`DeviceDisconnected`), an operation on the link timed out (`OperationTimedOut`), the device changed its services (`ServicesNotDiscovered`), or, on Android, a service discovery failed (`ServicesNotDiscovered` with the GATT status in `nativeStatus`, see below). It doesn't fire after `remove()`, and not when `destroy()` ends the subscription.
- A subscription doesn't survive its link. After a reconnect, subscribe again.
- `isSubscribedToCharacteristic()` is true while a subscription of this manager on the characteristic completed and hasn't ended.
- Android: when the OS accepted a `discoverServices()` but answered with an error, every subscription of that link ends with `ServicesNotDiscovered` (303, `nativeStatus`: the GATT status) and the call rejects with `ServicesDiscoveryFailed` (300). Android drops its service list when a discovery starts and replaces it with the answer, so after a failed discovery the old characteristics are gone. A discovery the OS refuses to start changes nothing.

#### Service Changed

When a device changes its GATT database it sends a Service Changed indication (Bluetooth Core Specification Vol 3 Part G §7.1). The link stays up, and the manager:

- ends the subscriptions on the changed services: `onEnded` gets `ServicesNotDiscovered` (303). Android doesn't tell which services changed, so it ends every subscription of the link;
- fails operations on the changed services with `ServicesNotDiscovered` until `discoverServices()` completed again (a discovery that was running when the change arrived fails with 303 too);
- reports `ConnectionEventType.ServicesChanged`.

The manager doesn't rediscover by itself. Your app does: call `discoverServices()` and subscribe again, or drop the link and let your reconnect path do both. Android reports Service Changed from Android 12 (API 31); older Android versions never do.

### ❗ Errors

Every promise rejects with a `BleError`, and every synchronous method throws one:

```typescript
import { BleError, BleErrorCode } from 'react-native-ble-nitro';

try {
  await ble.connect(deviceId, { timeoutMs: 10_000 });
} catch (error) {
  if (error instanceof BleError) {
    error.errorCode;    // BleErrorCode, e.g. BleErrorCode.OperationTimedOut
    error.nativeStatus; // Android GATT/HCI status or scan error code, iOS CBError/CBATTError code, if any
    error.deviceId;     // the canonical (uppercase) id of the failed operation's device, if any
    error.message;      // English, for logs; not part of the contract
  }
}
```

The codes have the same names and numbers as react-native-ble-plx's `BleErrorCode`:

| Code | Name | Meaning |
|---|---|---|
| 0 | `UnknownError` | Anything else, including an exception thrown by a native call (kept in `error.cause`) |
| 1 | `BluetoothManagerDestroyed` | `destroy()` was called; every completion that fires after that fails with it |
| 2 | `OperationCancelled` | The operation was cancelled, e.g. a pending connect by `disconnect()` |
| 3 | `OperationTimedOut` | A GATT operation took longer than 30 s (the link is taken down), or a connect longer than `timeoutMs` |
| 4 | `OperationStartFailed` | The OS refused to start the operation, or `timeoutMs` is `NaN`, 0 or negative |
| 5 | `InvalidIdentifiers` | A device id or UUID is malformed (see [UUID Handling](#uuid-handling)) |
| 100 | `BluetoothUnsupported` | The device has no BLE |
| 101 | `BluetoothUnauthorized` | The app lacks Bluetooth permission |
| 102 | `BluetoothPoweredOff` | Bluetooth is off |
| 103 | `BluetoothInUnknownState` | The Bluetooth state is not known yet |
| 104 | `BluetoothResetting` | Bluetooth is turning on or off |
| 105 | `BluetoothStateChangeFailed` | `requestBluetoothEnable()` failed (always on iOS) |
| 200 | `DeviceConnectionFailed` | The connect failed (Android: GATT status in `nativeStatus`, e.g. 133) |
| 201 | `DeviceDisconnected` | The link dropped; every pending operation of the device fails with it |
| 202 | `DeviceRSSIReadFailed` | Reading the RSSI failed |
| 203 | `DeviceAlreadyConnected` | Another connect to the device is pending |
| 204 | `DeviceNotFound` | The device is unknown, or `findAndConnect()` didn't find it |
| 205 | `DeviceNotConnected` | The device has no link (also `disconnect()` with nothing to disconnect) |
| 206 | `DeviceMTUChangeFailed` | The MTU exchange failed |
| 300 | `ServicesDiscoveryFailed` | Service discovery failed |
| 301 | `IncludedServicesDiscoveryFailed` | Included-service discovery failed |
| 302 | `ServiceNotFound` | The device has no such service |
| 303 | `ServicesNotDiscovered` | No discovery completed on this link, or the device's services changed since (also ends subscriptions on Service Changed, and on Android after a failed discovery) |
| 400 | `CharacteristicsDiscoveryFailed` | Characteristic discovery failed |
| 401 | `CharacteristicWriteFailed` | The write failed, the characteristic doesn't declare the write type, or the data is too long |
| 402 | `CharacteristicReadFailed` | The read failed, or the characteristic isn't readable |
| 403 | `CharacteristicNotifyChangeFailed` | The CCCD write of a subscribe or unsubscribe failed (`nativeStatus`: the GATT/ATT status), or the characteristic neither notifies nor indicates |
| 404 | `CharacteristicNotFound` | The service has no such characteristic |
| 405 | `CharacteristicsNotDiscovered` | Characteristics were not discovered yet |
| 406 | `CharacteristicInvalidDataFormat` | The write data isn't an `ArrayBuffer`, an `ArrayBufferView` or an array of integers from 0 to 255 |
| 501 | `DescriptorWriteFailed` | Not used by this library (a failed CCCD write is 403) |
| 502 | `DescriptorReadFailed` | A descriptor read failed |
| 600 | `ScanStartFailed` | The scan failed to start or stopped (Android scan error code in `nativeStatus`) |
| 601 | `LocationServicesDisabled` | Android needs location services on to scan |

A method that returns a promise never throws: invalid input (a malformed UUID, write data that isn't bytes, a `null` options object) rejects its promise.

### 🧵 Threading and ordering

- **One thread per manager.** On Android a dedicated HandlerThread receives every GATT callback, scan result and state change and issues every GATT operation; on iOS a dedicated serial DispatchQueue runs the `CBCentralManager` and every delegate call. Nothing runs on the UI thread, and the JS thread never touches the native state.
- **JS callbacks** run on the JS thread, in the order the OS delivered the events, across all devices and characteristics. A callback never runs inline in the call that registered it, also not when that call fails at once.
- **One operation at a time per device**, in call order (Android's GATT allows one outstanding operation per connection). Operations on different devices are independent. You may issue several operations without awaiting each: they queue.
- **Every operation completes exactly once**, with a result or a `BleError`.
- **Timeouts:** a GATT operation (discovery, read, write, subscribe, unsubscribe, RSSI, MTU) that the device doesn't answer within 30 s fails with `OperationTimedOut` and takes the link down. After an ATT transaction timed out no further request may be sent on that link (Bluetooth Core Specification Vol 3 Part F §3.3.3), and Android keeps its GATT client busy until the late answer, so every later operation would fail anyway. The operations queued behind it fail with `DeviceDisconnected`, its subscriptions end with `OperationTimedOut`, and the disconnect callback gets `interrupted = true` with `OperationTimedOut`. Android 14+ MTU requests never time out (see the connecting notes). A connect times out only with `timeoutMs`; otherwise the OS decides (Android about 30 s, iOS never).
- **Link loss:** when a link drops, every pending operation of the device fails with `DeviceDisconnected` and every subscription on it ends. `destroy()` fails pending operations with `BluetoothManagerDestroyed` and closes links silently, without firing listeners. `disconnect()` fails the queued operations at once.

### Flow control (writes without response)

`writeCharacteristic(..., false)` resolves when the OS accepted the write for sending: on Android when `onCharacteristicWrite` reports it, on iOS once `canSendWriteWithoutResponse` allows it. Awaiting each write therefore sends a burst as fast as the link allows, without overflowing the OS buffers and silently dropping packets:

```typescript
for (const chunk of chunks) {
  await ble.writeCharacteristic(deviceId, serviceUUID, characteristicUUID, chunk, false);
}
```

Writes issued without awaiting are paced the same way, since they queue per device; awaiting keeps memory bounded and lets you stop at the first failure.

### UUID Handling

Every method taking a UUID accepts, in any letter case:

- 4 or 8 hex digits: a 16- or 32-bit UUID, placed on the Bluetooth Base UUID `00000000-0000-1000-8000-00805F9B34FB` (Bluetooth Core Specification Vol 3 Part B §2.5.1);
- 32 hex digits;
- the 8-4-4-4-12 form.

Anything else (`'0x180d'`, `'180'`, braces, 5 hex digits) fails with `InvalidIdentifiers`: padding a malformed UUID would address another attribute than you meant. A method returning a promise rejects; a synchronous one throws. Every UUID the library returns is the lowercase 128-bit form.

```typescript
await ble.readCharacteristic(deviceId, '180f', '2a19');
await ble.readCharacteristic(deviceId, '0000180F-0000-1000-8000-00805F9B34FB', '00002a19-0000-1000-8000-00805f9b34fb');

const services = await ble.getServices(deviceId);
// ['0000180d-0000-1000-8000-00805f9b34fb', ...]
```

### Utility Functions

```typescript
// Normalize UUIDs to the lowercase 128-bit form (throws InvalidIdentifiers for a malformed one)
const fullUUID = BleNitro.normalizeGattUUID('180d');
// Returns: '0000180d-0000-1000-8000-00805f9b34fb'

const fullUUIDs = BleNitro.normalizeGattUUIDs(['180d', '180f']);
// Returns: ['0000180d-0000-1000-8000-00805f9b34fb', '0000180f-0000-1000-8000-00805f9b34fb']
```

### iOS Restore State

There is built-in support for iOS state restoration. You need to provide a unique identifier and a callback to handle restored peripherals. If no unique identifier is provided, state restoration is disabled. Keep the identifier stable across releases: iOS restores by it.

> [!CAUTION]
> From 1.7.0 on you have to create your own instance of `BleNitroManager` if you want to use state restoration. The singleton `BleNitro.instance()` will not have state restoration enabled by default anymore.

```typescript
import { BleNitroManager, BLEDevice } from 'react-native-ble-nitro';

const customBleInstance = new BleNitroManager({
  restoreIdentifier: 'my-unique-identifier', // unique identifier for state restoration
  onRestoredState: (peripherals: BLEDevice[]) => {
    console.log('Restored peripherals:', peripherals);
    // Handle restored peripherals, e.g. connect() to each one to install
    // a disconnect callback and continue using it
  }
});
```

`connect()` to a restored peripheral resolves at once when iOS kept it connected. When iOS still has a connection attempt pending for it, `connect()` takes that attempt over and a `timeoutMs` only rejects the call; iOS keeps trying. If the device connects later while no `connect()` waits, the manager keeps the link and reports a `Connected` [connection event](#connection-events), so listen for those to pick up such links. Subscriptions don't carry over a restoration: notifications that arrive before you subscribe again are not buffered.

If the manager is created early (e.g. at module load) but the code that handles restored peripherals starts later, omit `onRestoredState` from the options and call `onRestoredState(callback)` when ready: peripherals restored before a callback was set are kept and passed to the first callback, once.

```typescript
customBleInstance.onRestoredState((peripherals) => {
  console.log('Restored peripherals:', peripherals);
});
```

### TypeScript Types

```typescript
interface BLEDevice {
  id: string;   // Android: uppercase MAC address; iOS: uppercase peripheral UUID
  name: string; // '' when the device has no name
  rssi: number;
  manufacturerData: ManufacturerData;
  serviceData: ServiceData;
  serviceUUIDs: string[];
  isConnectable: boolean;
  isConnected: boolean;
}

// Advertised manufacturer-specific data, keyed by company identifier
interface ManufacturerData {
  companyIdentifiers: ManufacturerDataEntry[];
}

interface ManufacturerDataEntry {
  id: string;       // company identifier
  data: number[];   // raw manufacturer payload
}

// Advertised service data, keyed by service UUID
interface ServiceData {
  services: ServiceDataEntry[];
}

interface ServiceDataEntry {
  uuid: string;     // service UUID
  data: number[];   // raw service-data payload
}

interface ScanFilter {
  serviceUUIDs?: string[];
  rssiThreshold?: number;
  allowDuplicates?: boolean;
  androidScanMode?: AndroidScanMode;
}

interface ConnectOptions {
  autoConnectAndroid?: boolean;
  refreshGattAndroid?: boolean;
  timeoutMs?: number;
}

interface FindAndConnectOptions extends ConnectOptions {
  scanTimeout?: number;
  serviceUUIDs?: string[];
  onDisconnect?: DisconnectEventCallback;
  onFound?: (device: BLEDevice) => void;
}

interface CharacteristicProperties {
  read: boolean;
  write: boolean;
  writeWithoutResponse: boolean;
  notify: boolean;
  indicate: boolean;
}

enum ConnectionEventType {
  Connected = 'Connected',
  Disconnected = 'Disconnected',
  ServicesChanged = 'ServicesChanged',
}

interface ConnectionEvent {
  deviceId: string;     // canonical (uppercase) id
  type: ConnectionEventType;
  interrupted: boolean; // Disconnected: as in the disconnect callback; false otherwise
  error?: BleError;     // Disconnected: as in the disconnect callback
}

interface Subscription {
  remove: () => void;
}

interface AsyncSubscription {
  remove: () => Promise<void>;
}

class BleError extends Error {
  readonly errorCode: BleErrorCode;
  readonly nativeStatus?: number;
  readonly deviceId?: string;
}

enum BLEState {
  Unknown = 'Unknown',
  Resetting = 'Resetting',
  Unsupported = 'Unsupported',
  Unauthorized = 'Unauthorized',
  PoweredOff = 'PoweredOff',
  PoweredOn = 'PoweredOn'
}

enum AndroidScanMode {
  LowLatency = 'LowLatency',        // Highest power, fastest discovery
  Balanced = 'Balanced',            // Balanced power/discovery (default)
  LowPower = 'LowPower',            // Lowest power, slower discovery
  Opportunistic = 'Opportunistic',  // Only when other apps are scanning
}

enum AndroidConnectionPriority {
  Balanced = 'Balanced', // Balanced connection interval
  High = 'High',         // Lower latency, higher power
  LowPower = 'LowPower', // Lower power, higher latency
}

// Callback types
type StateChangeCallback = (state: BLEState) => void;
type ScanCallback = (device: BLEDevice) => void;
type ScanErrorCallback = (error: BleError) => void;
type RestoreStateCallback = (connectedPeripherals: BLEDevice[]) => void;
type DisconnectEventCallback = (deviceId: string, interrupted: boolean, error?: BleError) => void;
type CharacteristicUpdateCallback = (data: ArrayBuffer) => void;
type SubscriptionEndedCallback = (error: BleError) => void;
type ConnectionEventCallback = (event: ConnectionEvent) => void;
```

## 🧩 Using from native code (C++)

`ble.nativeObject` is the Nitro HybridObject behind a manager. Another Nitro module can take it and call the generated C++ interface, `margelo::nitro::co::zyke::ble::HybridNativeBleNitroSpec`, directly: for example to consume a high-rate notification stream in C++ without a JS hop per notification, while JS keeps using the same manager. Always use the manager's own object; a second native manager wouldn't have your links.

**1. Hand it over from JS.** In your module's spec (a C++ HybridObject), take it as `AnyHybridObject`:

```typescript
import type { AnyHybridObject, HybridObject } from 'react-native-nitro-modules';

export interface MyStream extends HybridObject<{ ios: 'c++'; android: 'c++' }> {
  attachBle(manager: AnyHybridObject): void;
}
```

```typescript
myStream.attachBle(ble.nativeObject);
```

**2. Cast it in C++.** Specs inherit `HybridObject` virtually, so it takes a `dynamic_pointer_cast` (which needs the spec's type info from `libBleNitro`, see linking below):

```cpp
#include <BleNitro/HybridNativeBleNitroSpec.hpp>

using margelo::nitro::co::zyke::ble::HybridNativeBleNitroSpec;

void HybridMyStream::attachBle(const std::shared_ptr<HybridObject>& manager) {
  _ble = std::dynamic_pointer_cast<HybridNativeBleNitroSpec>(manager);
  if (_ble == nullptr) {
    throw std::invalid_argument("attachBle() expects BleNitroManager.nativeObject");
  }
}
```

**3. Call it.** The C++ methods are the native spec (`src/specs/NativeBleNitro.nitro.ts`, whose doc comments are the contract): callback-based, without the promise layer. They accept the same UUID forms as the JS methods (see [UUID Handling](#uuid-handling)) and report UUIDs in the lowercase 128-bit form; anything else fails with `InvalidIdentifiers`.

```cpp
using margelo::nitro::ArrayBuffer;
using margelo::nitro::co::zyke::ble::BleError;

// Returns the subscription's id without waiting. Called from a thread other than the
// manager's, its callbacks may already run before this returns.
const double subscriptionId = _ble->subscribeToCharacteristic(deviceId, serviceUuid, characteristicUuid,
  [weakSink = std::weak_ptr<Sink>(_sink)](const std::shared_ptr<ArrayBuffer>& value) {
    // On the manager's thread. The buffer is this subscriber's own copy; it stays valid after returning.
    if (auto sink = weakSink.lock()) sink->push(value->data(), value->size());
  },
  [](const std::optional<BleError>& error) {
    // Once: after the CCCD write completed, or with the error (error->code, error->nativeStatus).
  },
  // Optional: called once when the subscription ends without unsubscribeFromCharacteristic
  // (link lost, disconnect(), operation timeout, services changed, Android: failed discovery).
  // std::nullopt for none.
  std::function<void(const BleError&)>([](const BleError& error) { /* ... */ }));

// Later: ends exactly this subscription, never another one on the same characteristic.
_ble->unsubscribeFromCharacteristic(subscriptionId, [](const std::optional<BleError>& error) {});
```

The generated signatures you call:

```cpp
double subscribeToCharacteristic(const std::string& deviceId, const std::string& serviceId,
    const std::string& characteristicId,
    const std::function<void(const std::shared_ptr<ArrayBuffer>&)>& updateCallback,
    const std::function<void(const std::optional<BleError>&)>& completionCallback,
    const std::optional<std::function<void(const BleError&)>>& endedCallback);
void unsubscribeFromCharacteristic(double subscriptionId,
    const std::function<void(const std::optional<BleError>&)>& callback);
std::optional<double> getMtu(const std::string& deviceId);
double subscribeToConnectionEvents(const std::function<void(const ConnectionEvent&)>& callback);
void unsubscribeFromConnectionEvents(double listenerId);
```

Subscription and listener ids are positive and never reused within the process. Subscriptions from C++ and JS on the same manager add up like any others: unsubscribing yours never turns off notifications another subscriber still needs. Each value is copied out of the OS's buffer before it reaches you; there is no zero-copy path. Every subscriber gets its own copy, on both platforms, so changing it never affects another subscriber.

**Callback rules.** A callback created in C++ runs directly on the manager's thread (Android: its HandlerThread; iOS: its CoreBluetooth queue), in the order the OS delivered the events, across all devices. JS callbacks hop to the JS thread instead; C++ ones never do. No callback runs inline in the call that registered it, and none runs from a synchronous method.

- Return quickly and never block: every other BLE event of the manager waits behind your callback.
- Never throw. On iOS the generated Swift-to-C++ wrappers are `noexcept`, so an exception terminates the process. Android catches it and logs it, and the event is lost. Catch everything inside the callback.
- No JSI in the callback: it is not on the JS thread. To reach JS, call a JS function your module received from Nitro (it hops to the JS thread).
- Asynchronous methods (`writeCharacteristic`, `subscribeToCharacteristic`, ...) may be called from a callback: they queue and run after the current callback returns, in call order.
- Synchronous methods (the getters, `stopScan`, `unsubscribeFromStateChange`, `unsubscribeFromConnectionEvents`) called from a callback run inline. Called from another thread they wait for the manager's thread, and so does `destroy()` (from a callback it doesn't wait). Never call one of them or `destroy()` while holding a lock that your BLE callbacks take: the manager's thread may be running such a callback, blocked on that lock, and both threads wait forever.
- From the moment `destroy()` is called, listeners (updates, ended, state, connection events, disconnect, scan results) never fire again and links close silently. Called from a thread other than the manager's, `destroy()` also waits until a listener that was already running has returned, so once it returns you may release your listener state. It doesn't wait for JS callbacks, which Nitro runs later on the JS thread. Every completion that fires after `destroy()` was called fails once with `BluetoothManagerDestroyed` (Android: on a process-wide fallback thread; iOS: on the manager's queue), and registration methods still return an id. A `startScan` whose start hadn't reached the OS yet reports `BluetoothManagerDestroyed` through its callback; a scan already running ends silently.

**Callback lifetime.** The manager keeps a copy of each `std::function` until the subscription or listener is over. On Android the copy lives in a Java object, so it is destroyed later, on a garbage collector thread, at a time you don't control. Capture `std::weak_ptr`, not `std::shared_ptr` or `this`, for anything whose lifetime matters, and don't rely on the capture's destructor running on a particular thread or at a particular time.

**Android threads.** Every call goes through JNI, so it must come from a thread attached to the JVM: the JS thread, the manager's thread (inside a callback), or a thread you attached. Attach a thread you created in C++ with `facebook::jni::ThreadScope::WithClassLoader` before its first call into the manager, and run the calls inside it; a plain attach can't find the app's classes.

**FastNative.** nitrogen 0.35 marks the JNI method behind every generated callback class (`Func_*.kt`, `invoke_cxx`) `@FastNative`. The garbage collector can't suspend a thread while it runs a `@FastNative` method, so a C++ callback that waits on a mutex held by a thread calling into Java during a collection hangs the whole app. This library strips the annotation after every nitrogen run (`scripts/strip-fast-native.mjs`, part of `npm run nitro-codegen`), and its Gradle build fails while a generated Kotlin file still has it. The check covers only this library's bindings: if your own Nitro module hands C++ callbacks to Java, apply the same step to its generated code.

**Regenerating bindings.** The fork pins `nitrogen` to exactly 0.35.2 and declares `react-native-nitro-modules` `~0.35.0` as its peer: the generated C++ and JNI code depends on the nitrogen minor. If you regenerate this library's bindings yourself (e.g. a vendored copy), use nitrogen 0.35.2 and run `node scripts/strip-fast-native.mjs` right after it, or run `npm run nitro-codegen`, which does both.

**Linking on Android.** The library publishes a prefab package `react-native-ble-nitro` with the module `BleNitro` (`libBleNitro.so`) and the generated C++ headers. In your module's `build.gradle`:

```gradle
android {
  buildFeatures {
    prefab true
  }
}

dependencies {
  implementation project(":react-native-ble-nitro")
}
```

and in its `CMakeLists.txt`:

```cmake
find_package(react-native-ble-nitro REQUIRED CONFIG)
target_link_libraries(MyStream react-native-ble-nitro::BleNitro)
```

**Linking on iOS.** Depend on the `BleNitro` pod, which exposes the generated C++ headers:

```ruby
s.dependency 'BleNitro'
```

## Migrating from 2.x to 3.0

3.0 makes subscriptions shareable, enforces the GATT limits before anything reaches the device, and handles operation timeouts and Service Changed by ending what they break instead of leaving it silently stuck.

**Subscriptions**
- Subscriptions add up. In 2.x subscribing again to a characteristic replaced the previous subscription; now both stay active, each with its own callbacks, and notifications stay on until the last one is removed. Code that relied on the replacement must `remove()` the old subscription itself.
- `ble.unsubscribeFromCharacteristic(deviceId, serviceUUID, characteristicUUID)` is removed. Keep the subscription and call its `remove()`.
- `subscribeToCharacteristic()` takes an optional fifth argument, `onEnded(error)`, called once when the subscription ends without `remove()` (link lost, `disconnect()`, operation timeout, services changed, on Android a failed service discovery). After that, `remove()` resolves without doing anything.
- A failed CCCD write is `CharacteristicNotifyChangeFailed` (403) with the GATT/ATT status on both platforms; 2.x on Android reported it as `DescriptorWriteFailed` (501).
- `isSubscribedToCharacteristic()` is true only while a subscription of this manager is active on the characteristic. 2.x on iOS returned the characteristic's `isNotifying`, whoever turned notifications on.

**GATT rules**
- An operation the device doesn't answer within 30 s takes the link down (2.x moved on to the next operation). Expect the disconnect callback with `interrupted = true` and `OperationTimedOut`, and reconnect.
- Writes are limited to 512 bytes, and writes without response to `min(getMtu() - 3, 512)`. Longer data rejects with `CharacteristicWriteFailed` and nothing is sent; 2.x let Android cut it short.
- Operations check the characteristic's declared properties: a read of a characteristic without `read` fails with 402, a write type it doesn't declare with 401, a subscription to one that neither notifies nor indicates with 403.
- After a Service Changed indication, subscriptions on the changed services end with `ServicesNotDiscovered` (303) and operations on them fail with 303 until `discoverServices()` ran again (see [Service Changed](#service-changed)).
- `discoverServices()` discovers the characteristics too, on both platforms.

**Input**
- UUIDs are parsed strictly (4, 8 or 32 hex digits, or the 8-4-4-4-12 form). Anything else fails with `InvalidIdentifiers`; methods returning a promise reject instead of throwing.
- `writeCharacteristic()` also takes any `ArrayBufferView` (exactly the bytes it views). A `number[]` must hold integers from 0 to 255, else it rejects with `CharacteristicInvalidDataFormat`.
- `requestMTU()` takes an integer from 23 to 517, else it rejects with `DeviceMTUChangeFailed`. A `timeoutMs` of `NaN`, 0 or less rejects with `OperationStartFailed`.

**Behavior worth rechecking**
- Device ids in callbacks, events and scan results are canonical (uppercase on both platforms). Methods accept any letter case, `findAndConnect()` compares ids that way, and `connect()` and `findAndConnect()` resolve with the canonical id. `BleError.deviceId` carries the canonical id too.
- A success the native side reported before `destroy()` rejects with `BluetoothManagerDestroyed` if it reaches JS after `destroy()`.
- `AsyncSubscription.remove()` returns the same promise on every call.
- `findAndConnect()` rejects at once with `OperationCancelled` when another scan or `stopScan()` ends its scan, and with `BluetoothManagerDestroyed` on `destroy()`.
- On Android a JS reload destroys every manager the old runtime created.
- `requestBluetoothEnable()` on Android resolves once the user turned Bluetooth on and rejects with `OperationCancelled` when they declined.

**New**
- `getMtu()`, `getCharacteristicProperties()`, `onConnectionEvent()` with `ConnectionEventType` (`Connected`, `Disconnected`, `ServicesChanged`), and the `serviceUUIDs` option of `findAndConnect()`.

**Expo plugin**
- Legacy `BLUETOOTH` and `BLUETOOTH_ADMIN` are capped at API 30. `BLUETOOTH_ADVERTISE` is added only with `androidAdvertisingEnabled`. With `neverForLocation` the location permissions the plugin adds are capped at API 30. `isBackgroundEnabled` adds `ACCESS_BACKGROUND_LOCATION` (capped at API 30) and no longer touches the BLE feature, whose `android:required` is the new `androidBleRequired` option. See [Expo Plugin Options](#expo-plugin-options).

**Native (C++) consumers**
- `subscribeToCharacteristic` takes a sixth argument, `endedCallback` (`std::optional<std::function<void(const BleError&)>>`, `std::nullopt` for none), and returns the subscription id.
- `unsubscribeFromCharacteristic(subscriptionId, callback)` ends one subscription by id; the characteristic-keyed form is gone.
- `subscribeToStateChange` and `subscribeToConnectionEvents` return listener ids, removed with `unsubscribeFromStateChange(id)` and `unsubscribeFromConnectionEvents(id)`.
- `discoverServicesWithCharacteristics` and the `OperationResult` type are removed: `discoverServices` discovers characteristics.
- New: `getMtu`, `getCharacteristicProperties`.
- Callbacks never run inline on the calling thread. Read the [callback rules](#-using-from-native-code-c) again, especially the ones on locks, exceptions and capture lifetime.
- Rebuild against `react-native-nitro-modules` 0.35. Bindings regenerated by hand need nitrogen 0.35.2 followed by `scripts/strip-fast-native.mjs`.

## 🔁 Migrating from 1.x to 2.0

2.0 makes the library reliable under load (per-device operation queues, write flow control, link-loss handling, a dedicated BLE thread on both platforms) and gives every failure a code. The API changes:

**Errors**
- Every promise rejects with a `BleError` (`errorCode`, `nativeStatus`, `deviceId`) instead of an `Error` with a platform-specific message; synchronous methods throw `BleError`. Branch on `error.errorCode`, not on `error.message`.
- `BleTimeoutError` is removed. Timeouts are `BleError`s with `errorCode === BleErrorCode.OperationTimedOut`, whether they come from a connect's `timeoutMs` or the native 30 s per-operation timeout. The JS-side 30 s timeout of `getServicesWithCharacteristics` is gone: discovery now times out natively, like every other GATT operation, and the native queue moves on.

**Connection**
- `connect(deviceId, onDisconnect?, autoConnectAndroid?)` is now `connect(deviceId, options?, onDisconnect?)` with `options: { autoConnectAndroid?, refreshGattAndroid?, timeoutMs? }`.
- `connect()` no longer resolves early for a connected device without telling the native side: it always connects natively, which for a connected device resolves and installs the new `onDisconnect`.
- `onDisconnect`'s `error` is a `BleError | undefined` instead of a string.
- `disconnect()` resolves with `void` instead of the device id. It no longer resolves early when `isConnected()` is false: it cancels a pending connect, and rejects with `DeviceNotConnected` when there is nothing to disconnect.
- `requestMTU()` returns `Promise<number>` (was a synchronous `number`) with the ATT MTU in effect: the negotiated value on Android (1.x returned the requested one), CoreBluetooth's MTU on iOS (1.x returned the maximum write length, which is 3 less).
- `requestConnectionPriority()` returns `Promise<void>` (was `boolean`).
- `findAndConnect()` accepts every `connect()` option, and rejects with `DeviceNotFound` when the scan times out (was `Error('Scan timed out')`).
- Operations no longer check `isConnected()` first (that cost a native round trip, on Android a binder call, per write); an operation on a device without a link fails natively with `DeviceNotConnected`, and `getCharacteristics()` no longer throws for a disconnected device.

**Data**
- `readCharacteristic()` resolves with an `ArrayBuffer` (was `number[]`).
- `writeCharacteristic()` accepts an `ArrayBuffer` or a `number[]` (3.0 also accepts any `ArrayBufferView`), and resolves with an `ArrayBuffer` of the bytes written (was `number[]`). A write without response resolves when the OS accepted it, no longer at once (see [Flow control](#flow-control-writes-without-response)).
- The `subscribeToCharacteristic()` callback is `(data: ArrayBuffer) => void` (was `(characteristicId, data: number[])`).
- `AsyncSubscription.remove()` rejects when unsubscribing fails (1.x swallowed the error). The `remove()` of a subscription that a newer one to the same characteristic replaced does nothing (changed again in 3.0: subscriptions add up, see above).
- Scan results keep `number[]` advertisement data.

**Scanning and state**
- `startScan()`'s `onError` receives a `BleError` (was a string) on both platforms; without `onError`, a scan failure is thrown. Starting a scan while one runs replaces it (1.x ignored the call). There is no default `rssiThreshold` anymore (was -100). No callback of a stopped scan is called after `stopScan()`.
- `subscribeToStateChange()` supports any number of subscribers; `remove()` removes only its own (1.x had one global subscription).
- `discoverServices()` and `requestBluetoothEnable()` resolve with `void` (were `true`).

**New**
- `destroy()` releases the manager; `nativeObject` exposes it to native code (see [Using from native code](#-using-from-native-code-c)).
- `onRestoredState(callback)` is no longer deprecated.

**Removed**
- The `ConnectionCallback` and `OperationCallback` types, and the helper functions exported by `react-native-ble-nitro/manager` (`mapNativeBLEStateToBLEState`, `mapAndroidScanModeToNativeAndroidScanMode`, `mapAndroidConnectionPriorityToNativeAndroidConnectionPriority`, `convertNativeBleDeviceToBleDevice`, `arrayBufferToByteArray`, `byteArrayToArrayBuffer`).

## Known limits

These are deliberate gaps, not bugs:

- Android scans report legacy advertisements only: the library doesn't turn on extended (Bluetooth 5) advertising reports.
- Android `connect()` doesn't take an LE address type (see the connecting notes).
- Notifications of characteristics iOS restored arrive only to subscriptions made after the restoration; earlier ones are not buffered.
- There is no MTU-changed event. Read `getMtu()` when you need the current value.
- The manager doesn't rediscover services after Service Changed; the app decides when (see [Service Changed](#service-changed)).
- iOS keeps every peripheral a scan found (to connect it later without retrieving it) until the next scan starts, so one long unfiltered scan in a crowded place holds many.

## 🏗️ Architecture

### Nitro Modules Foundation

Built on [Nitro Modules](https://nitro.margelo.com/) for:

- **Direct JSI Communication**: No React Native bridge overhead
- **Type-Safe Bindings**: Compile-time type checking across JS/Native boundary
- **High Performance**: Near-native performance for all operations
- **Memory Efficient**: Optimal memory management with smart references

### Platform Implementation

- **iOS**: ✅ Complete Swift implementation using Core Bluetooth
- **Android**: ✅ Complete Kotlin implementation using Android BLE APIs
- **Shared C++**: Common logic and type definitions via Nitro Modules

## ⚙️ Configuration

### Expo Plugin Options

```typescript
interface BleNitroPluginProps {
  isBackgroundEnabled?: boolean;        // Android: background discovery on Android 10-11 (default false)
  neverForLocation?: boolean;           // Android: assert scans never derive location (default false)
  androidBleRequired?: boolean;         // Android: uses-feature bluetooth_le required (default false)
  androidAdvertisingEnabled?: boolean;  // Android: declare BLUETOOTH_ADVERTISE (default false)
  modes?: ('peripheral' | 'central')[]; // iOS background modes
  bluetoothAlwaysPermission?: string | false; // iOS permission message
  iOSLazyInit?: boolean;                // iOS: lazy init until the first BLE call (default false)
}
```

The plugin adds what the library needs and never narrows a permission declared elsewhere (by the app, another plugin or `android.permissions`). The exceptions are the legacy permissions and what the plugin owns outright (the `neverForLocation` flag, the feature's `android:required`, `BLENitroLazyInit`): those follow the config both ways, also on an existing entry, so turning an option off and running `expo prebuild` again without `--clean` undoes it.

- `isBackgroundEnabled`: adds `ACCESS_BACKGROUND_LOCATION` with `maxSdkVersion` 30, which a service needs to discover devices on Android 10 and 11. It is a runtime permission there: request it after the foreground location permission. From Android 12, `BLUETOOTH_SCAN` covers scanning, so users there are never asked for background location because of this option. An app that derives location from scans (no `neverForLocation`) and scans in the background on Android 12+ declares `ACCESS_BACKGROUND_LOCATION` itself. The plugin adds no foreground service.
- `neverForLocation`: `true` gives `BLUETOOTH_SCAN` `usesPermissionFlags="neverForLocation"` and caps the `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` entries the plugin adds at API 30, so on Android 12+ scanning needs only the Nearby devices permission and location is never granted there. Android 11 and lower still need location to scan. Android filters some beacons out of the results of an app with this flag. `false` removes the flag and declares fine and coarse location for every API level (removing a `maxSdkVersion`); request both together, since Android 12+ ignores a request for fine location alone.
- `androidBleRequired`: the `android:required` of `<uses-feature android:name="android.hardware.bluetooth_le">`. `true` hides the app on Google Play from devices without BLE.
- `androidAdvertisingEnabled`: adds `BLUETOOTH_ADVERTISE` (Android 12+). The library never advertises; set this only when other code in the app does.
- `modes`: `'central'` adds `bluetooth-central` (scan, connect and get notifications in the background); `'peripheral'` adds `bluetooth-peripheral`, which only an app acting as a peripheral through other code needs. Other values are ignored with a warning. Modes already in `Info.plist` are kept, and none is written twice.
- `bluetoothAlwaysPermission`: `NSBluetoothAlwaysUsageDescription`. A string sets it. When absent, an existing value is kept, otherwise the default "Allow $(PRODUCT_NAME) to connect to bluetooth devices" is used. `false` leaves `Info.plist` alone. iOS terminates an app that uses CoreBluetooth without this key.
- `iOSLazyInit`: sets `BLENitroLazyInit` in `Info.plist`, and removes it when `false` (see below).

### React Native CLI

To use lazy BLE initialization, add the following to your `Info.plist`:

```xml
<key>BLENitroLazyInit</key>
<true/>
```


### Lazy initialization
With iOS Lazy initialization, BLE will be automatically initialized on the first API call (e.g. `startScan()`, `connect()`, `state()`), which will also trigger the permission dialog. Optionally, you can call `iosLazyInit()` to explicitly initialize BLE ahead of time:

```typescript
bleNitro.iosLazyInit();
```

### iOS Background Modes

```json
{
  "modes": ["central"]
}
```

Adds `bluetooth-central` to `UIBackgroundModes`, so the app can scan, connect and receive notifications in the background. A background app gets scan results only for scans that filter by service UUID.

### Android Permissions

What the plugin declares:

```xml
<!-- Android 11 and lower -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />

<!-- Android 12+ ("Nearby devices"); the flag only with neverForLocation -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Scanning location: maxSdkVersion 30 only with neverForLocation -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="30" />

<!-- Only with isBackgroundEnabled -->
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" android:maxSdkVersion="30" />

<!-- Only with androidAdvertisingEnabled -->
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />

<!-- required = androidBleRequired -->
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
```

## Android Flow with Permission Handling

Request what the manifest lets Android grant. With `neverForLocation`, location is capped at API 30, so Android 12+ never grants it: asking for it there and requiring it to be granted would always fail.

```ts
import { PermissionsAndroid, Platform } from 'react-native';

// Match your plugin config
const NEVER_FOR_LOCATION = true;

const requestPermissionsAndroid = async (): Promise<boolean> => {
  if (Platform.OS !== 'android') {
    return true;
  }
  const { PERMISSIONS, RESULTS } = PermissionsAndroid;
  const location = [PERMISSIONS.ACCESS_FINE_LOCATION, PERMISSIONS.ACCESS_COARSE_LOCATION];
  const wanted =
    Platform.Version < 31
      ? location
      : [
          PERMISSIONS.BLUETOOTH_SCAN,
          PERMISSIONS.BLUETOOTH_CONNECT,
          ...(NEVER_FOR_LOCATION ? [] : location),
        ];
  const result = await PermissionsAndroid.requestMultiple(wanted);
  return wanted.every((permission) => result[permission] === RESULTS.GRANTED);
};

const hasPermissions = await requestPermissionsAndroid();

// Then start scanning or other operations
```

Without `neverForLocation`, Android 12+ delivers scan results only with fine location, so the sample asks for both location permissions there too.

## 🔧 Development

### Building the Library

```bash
# Install dependencies
npm install

# Generate native Nitro code (nitrogen 0.35.2, then the FastNative strip step)
npm run nitro-codegen

# Build TypeScript
npm run build

# Run the JS tests (see CONTRIBUTING.md for the Swift and Kotlin unit tests)
npm test

# Lint code
npm run lint
```

### Node not found with Android Studio on Mac

Start Android Studio from terminal to inherit correct PATH:

```sh
open -a Android\ Studio.app
```

### Project Structure

```
react-native-ble-nitro/
├── src/
│   ├── specs/              # Nitro module TypeScript specs
│   ├── manager.ts          # BleNitroManager, BleError
│   └── __tests__/          # Jest tests
├── nitrogen/generated/     # Generated native code (Nitro, not committed)
├── plugin/                 # Expo config plugin
├── scripts/                # strip-fast-native.mjs (run after nitrogen)
├── ios/                    # iOS implementation (Swift); ios/Core + ios/CoreTests: SwiftPM package
├── android/                # Android implementation (Kotlin) and its unit tests
└── example/                # Example Expo app
```

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

### Development Setup

1. **Fork the repository** on GitHub
2. **Clone your fork**: `git clone https://github.com/YOUR_USERNAME/react-native-ble-nitro.git`
3. **Add this repository as upstream**: `git remote add upstream https://github.com/EngineMon/react-native-ble-nitro.git`
4. **Install dependencies**: `npm install`
5. **Generate Nitro code**: `npm run nitro-codegen`
6. **Make your changes** and run tests: `npm test`
7. **Submit a pull request** to EngineMon/react-native-ble-nitro

## 📄 License

MIT License - see [LICENSE](./LICENSE) file.

## 🙏 Acknowledgments

- [Zyke](https://zyke.co) and [Phil Schaffarzyk](https://github.com/ps73) - Authors of [react-native-ble-nitro](https://github.com/zykeco/react-native-ble-nitro), which this fork builds on, developed for [Zyke Band](https://zykeband.com?utm_source=github&utm_medium=readme&utm_campaign=opensource)
- [Marc Rousavy](https://github.com/mrousavy) - Creator of Nitro Modules and CEO of Margelo
- [Nitro Modules](https://nitro.margelo.com/) - High-performance native module framework
- [Margelo](https://margelo.com/) - Nitro Modules creators
- [Alvinotuya84](https://github.com/Alvinotuya84) - For the API inspiration I took from his repo [react-native-bluetooth-nitro-nexus](https://github.com/Alvinotuya84/react-native-bluetooth-nitro-nexus)

## 📞 Support

- 🐛 **Bug Reports and Questions**: [GitHub Issues](https://github.com/EngineMon/react-native-ble-nitro/issues)
- 📖 **Documentation**: this README; the native contract is documented in [`src/specs/NativeBleNitro.nitro.ts`](./src/specs/NativeBleNitro.nitro.ts)

---

**Made with ❤️ for the React Native community**
