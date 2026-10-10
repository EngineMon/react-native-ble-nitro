# react-native-ble-nitro

[![npm version](https://badge.fury.io/js/react-native-ble-nitro.svg)](https://badge.fury.io/js/react-native-ble-nitro)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A high-performance React Native BLE library built on [Nitro Modules](https://nitro.margelo.com/).

Originally developed for [Zyke Band](https://zykeband.com?utm_source=github&utm_medium=readme&utm_campaign=opensource) - a fitness and health tracker created by a small team.

> [!IMPORTANT]
> 2.0 changes the API. See [Migrating from 1.x to 2.0](#-migrating-from-1x-to-20).

## ✨ Features

- 🚀 **High Performance**: Built on Nitro Modules with JSI for zero-overhead native communication; characteristic values are zero-copy `ArrayBuffer`s
- 📱 **iOS Support**: Complete iOS implementation with Swift and Core Bluetooth
- 🤖 **Android Support**: Complete Android implementation with Kotlin and Android BLE APIs
- 🧵 **Off the main thread**: each manager runs on its own thread (Android HandlerThread, iOS serial DispatchQueue)
- 🚦 **Reliable GATT**: operations on a device run one at a time in call order, time out after 30 s, and fail when the link drops
- 🌊 **Flow control**: a write without response resolves when the OS accepted it, so awaiting each write paces a burst
- ❗ **Typed errors**: every failure is a `BleError` with a numeric code (the same numbers as react-native-ble-plx) and the platform status
- 🧩 **C++ API**: other native modules can drive the manager from C++, e.g. to consume notifications without touching the JS thread
- 🎯 **Type-Safe**: Full TypeScript support with comprehensive type definitions
- 📡 **Advertisement Data**: Extract advertised service data and manufacturer data from scan results
- 🔧 **Expo Ready**: Built-in Expo config plugin for easy setup
- 🏗️ **New Architecture**: Full support for React Native's new architecture

## 🚀 Quick Start

### Installation

```bash
npm install react-native-nitro-modules react-native-ble-nitro
```

### Expo Setup

Add the plugin to your `app.json` or `app.config.js`:

```json
{
  "expo": {
    "plugins": [
      [
        "react-native-ble-nitro",
        {
          "isBackgroundEnabled": true,
          "modes": ["peripheral", "central"],
          "bluetoothAlwaysPermission": "Allow $(PRODUCT_NAME) to connect to bluetooth devices"
        }
      ]
    ]
  }
}
```

Then prebuild and run:

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

// Release the manager (scans, links, OS resources) when you no longer need it,
// e.g. on a JS reload. Don't destroy the shared BleNitro.instance().
ble.destroy();
```

### Complete API Reference

#### 🔌 Bluetooth State Management

```typescript
// Check if Bluetooth is enabled
const isEnabled = ble.isBluetoothEnabled();

// Get current Bluetooth state
const state = ble.state();
// Returns: BLEState.PoweredOn, BLEState.PoweredOff, etc.

// Request to enable Bluetooth (Android only; rejects with BluetoothStateChangeFailed on iOS)
await ble.requestBluetoothEnable();

// Subscribe to state changes. Any number of subscriptions may exist.
const subscription = ble.subscribeToStateChange((state) => {
  console.log('Bluetooth state changed:', state);
}, true); // true = emit initial state

// Removes only this subscription
subscription.remove();

// Open Bluetooth settings
await ble.openSettings();

// Explicitly initialize BLE on iOS (optional, iOS only)
// Useful to trigger the Bluetooth permission dialog at a specific moment
// when using lazy iOS initialization.
ble.iosLazyInit();
```

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

#### 🔗 Device Connection

```typescript
// Connect to a device with disconnect event handling
const deviceId = await ble.connect(deviceId, {
  autoConnectAndroid: false, // Optional: Android connectGatt autoConnect (default false)
  refreshGattAndroid: true,  // Optional: Android: clear the OS GATT cache right after connecting (default false)
  timeoutMs: 10_000,         // Optional: fail with OperationTimedOut and cancel the link attempt
}, (deviceId, interrupted, error) => {
  if (interrupted) {
    // The device or the OS dropped the link; error is a BleError (DeviceDisconnected + status)
    console.log('Connection interrupted:', error);
  } else {
    // disconnect() or destroy()
    console.log('Disconnected intentionally');
  }
});

// Connect without options or disconnect callback
const deviceId = await ble.connect(deviceId);

// Connecting to a device that is already connected (e.g. restored by iOS) resolves
// and installs the new disconnect callback.

// You can also use findAndConnect to scan and connect in one step
// This could be useful for reconnecting after app restart or when device was disconnected unexpectedly
const deviceId = await ble.findAndConnect(deviceId, {
  scanTimeout: 4000, // default 5000ms; rejects with DeviceNotFound when the device isn't found
  refreshGattAndroid: true, // any connect() option
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

// MTU: resolves with the ATT MTU in effect. Android negotiates the requested value;
// iOS negotiates by itself and returns its MTU.
const mtu = await ble.requestMTU(deviceId, 517);
const maxWritePayload = mtu - 3;

// Request Android connection priority while connected (Android only; resolves at once on iOS).
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

#### 🔧 Service Discovery

```typescript
// Discover all services for a device
await ble.discoverServices(deviceId);

// Discover services and get their UUIDs
const services = await ble.getServices(deviceId);
// Returns: ['0000180d-0000-1000-8000-00805f9b34fb', '0000180f-0000-1000-8000-00805f9b34fb', ...]
// Always returns full lowercase 128-bit UUIDs

// Get services with their characteristics (waits for characteristic discovery to complete)
const servicesWithCharacteristics = await ble.getServicesWithCharacteristics(deviceId);
// Returns: [{ uuid: '0000180d-0000-1000-8000-00805f9b34fb', characteristics: ['00002a37-0000-1000-8000-00805f9b34fb', ...] }, ...]

// Characteristics of a discovered service
const characteristics = ble.getCharacteristics(deviceId, '180d');
// Returns: ['00002a37-0000-1000-8000-00805f9b34fb', '00002a38-0000-1000-8000-00805f9b34fb', ...]
```

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

#### ✍️ Writing Characteristics

```typescript
// Write to a characteristic with response.
// data is an ArrayBuffer (passed as is) or a number[] (converted once).
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

The bytes are copied during the call, so you may reuse or change the buffer as soon as `writeCharacteristic` returns. See [Flow control](#flow-control-writes-without-response) for bursts.

#### 📡 Characteristic Notifications

> [!IMPORTANT]
> There is one subscription per characteristic. Subscribing again to the same characteristic replaces the previous subscription: it gets no more values, and its `remove()` does nothing.

```typescript
// Resolves once the device acknowledged the subscription (CCCD written)
const subscription = await ble.subscribeToCharacteristic(
  deviceId,
  serviceUUID,
  characteristicUUID,
  (data) => {
    // data: ArrayBuffer of its own for every value (zero-copy from native)
    console.log('Received notification:', new Uint8Array(data));
  }
);

// Unsubscribe from notifications. No value is delivered after remove() is called.
// Rejects with a BleError if the unsubscribe fails (e.g. DeviceNotConnected).
await subscription.remove();

// Or unsubscribe directly
await ble.unsubscribeFromCharacteristic(deviceId, serviceUUID, characteristicUUID);

// Check if a characteristic is currently subscribed to notifications
const isSubscribed = ble.isSubscribedToCharacteristic(deviceId, serviceUUID, characteristicUUID);
// Returns false for disconnected or unknown devices without throwing
```

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
    error.deviceId;     // the device of the failed operation, if any
    error.message;      // English, for logs; not part of the contract
  }
}
```

The codes have the same names and numbers as react-native-ble-plx's `BleErrorCode`:

| Code | Name | Meaning |
|---|---|---|
| 0 | `UnknownError` | Anything else, including an exception thrown by a native call (kept in `error.cause`) |
| 1 | `BluetoothManagerDestroyed` | `destroy()` was called; pending operations fail with it |
| 2 | `OperationCancelled` | The operation was cancelled, e.g. a pending connect by `disconnect()` |
| 3 | `OperationTimedOut` | A GATT operation took longer than 30 s, or a connect longer than `timeoutMs` |
| 4 | `OperationStartFailed` | The OS refused to start the operation |
| 5 | `InvalidIdentifiers` | A device, service or characteristic identifier is malformed |
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
| 303 | `ServicesNotDiscovered` | Services were not discovered yet |
| 400 | `CharacteristicsDiscoveryFailed` | Characteristic discovery failed |
| 401 | `CharacteristicWriteFailed` | The write failed |
| 402 | `CharacteristicReadFailed` | The read failed |
| 403 | `CharacteristicNotifyChangeFailed` | Subscribing or unsubscribing (the CCCD write) failed |
| 404 | `CharacteristicNotFound` | The service has no such characteristic |
| 405 | `CharacteristicsNotDiscovered` | Characteristics were not discovered yet |
| 406 | `CharacteristicInvalidDataFormat` | The value has an invalid format |
| 501 | `DescriptorWriteFailed` | A descriptor write failed |
| 502 | `DescriptorReadFailed` | A descriptor read failed |
| 600 | `ScanStartFailed` | The scan failed to start or stopped (Android scan error code in `nativeStatus`) |
| 601 | `LocationServicesDisabled` | Android needs location services on to scan |

After `destroy()`, every method throws or rejects with `BluetoothManagerDestroyed`, except those that only release something (`stopScan()`, `Subscription.remove()`, `AsyncSubscription.remove()`, `destroy()`), which do nothing.

### 🧵 Threading and ordering

- **One thread per manager.** On Android a dedicated HandlerThread receives every GATT callback, scan result and state change and issues every GATT operation; on iOS a dedicated serial DispatchQueue runs the `CBCentralManager` and every delegate call. Nothing runs on the UI thread, and the JS thread never touches the native state.
- **JS callbacks** run on the JS thread, in the order the OS delivered the events, across all devices and characteristics.
- **One operation at a time per device**, in call order (Android's GATT allows one outstanding operation per connection). Operations on different devices are independent. You may issue several operations without awaiting each: they queue.
- **Every operation completes exactly once**, with a result or a `BleError`.
- **Timeouts:** every queued GATT operation (discovery, read, write, subscribe, unsubscribe, RSSI, MTU) fails with `OperationTimedOut` after 30 s, and the device's queue moves on. A connect times out only with `timeoutMs`; otherwise the OS decides (Android about 30 s, iOS never).
- **Link loss:** when a link drops, every pending operation of the device fails with `DeviceDisconnected`; `destroy()` fails them with `BluetoothManagerDestroyed`.

### Flow control (writes without response)

`writeCharacteristic(..., false)` resolves when the OS accepted the write for sending: on Android when `onCharacteristicWrite` reports it, on iOS once `canSendWriteWithoutResponse` allows it. Awaiting each write therefore sends a burst as fast as the link allows, without overflowing the OS buffers and silently dropping packets:

```typescript
for (const chunk of chunks) {
  await ble.writeCharacteristic(deviceId, serviceUUID, characteristicUUID, chunk, false);
}
```

Writes issued without awaiting are paced the same way, since they queue per device; awaiting keeps memory bounded and lets you stop at the first failure.

### UUID Handling

**🔧 Automatic UUID Conversion**

This library automatically handles UUID conversion between 16-bit, 32-bit, and 128-bit formats:

```typescript
// All input methods accept both short and long form UUIDs, in any case:
await ble.readCharacteristic(deviceId, '180f', '2a19');           // Short form ✅
await ble.readCharacteristic(deviceId, '0000180f-0000-1000-8000-00805f9b34fb', '00002a19-0000-1000-8000-00805f9b34fb'); // Long form ✅

// All output methods return full lowercase 128-bit UUIDs:
const services = await ble.getServices(deviceId);
// Always returns: ['0000180d-0000-1000-8000-00805f9b34fb', ...]
```

### Utility Functions

```typescript
// Manually normalize UUIDs to full lowercase 128-bit format (rarely needed)
const fullUUID = BleNitro.normalizeGattUUID('180d');
// Returns: '0000180d-0000-1000-8000-00805f9b34fb'

// Normalize multiple UUIDs
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

If the manager is created early (e.g. at module load) but the code that handles restored peripherals starts later, omit `onRestoredState` from the options and call `onRestoredState(callback)` when ready: peripherals restored before a callback was set are kept and passed to the first callback, once.

```typescript
customBleInstance.onRestoredState((peripherals) => {
  console.log('Restored peripherals:', peripherals);
});
```

### TypeScript Types

```typescript
interface BLEDevice {
  id: string;   // Android: MAC address; iOS: peripheral UUID
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
  onDisconnect?: DisconnectEventCallback;
  onFound?: (device: BLEDevice) => void;
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
#include <HybridNativeBleNitroSpec.hpp>

using margelo::nitro::co::zyke::ble::HybridNativeBleNitroSpec;

void HybridMyStream::attachBle(const std::shared_ptr<HybridObject>& manager) {
  _ble = std::dynamic_pointer_cast<HybridNativeBleNitroSpec>(manager);
  if (_ble == nullptr) {
    throw std::invalid_argument("attachBle() expects BleNitroManager.nativeObject");
  }
}
```

**3. Call it.** The C++ methods are the native spec (`src/specs/NativeBleNitro.nitro.ts`, whose doc comments are the contract): callback-based, no UUID normalization, so pass full lowercase 128-bit UUIDs (`BleNitroManager.normalizeGattUUID` gives them).

```cpp
using margelo::nitro::ArrayBuffer;
using margelo::nitro::co::zyke::ble::BleError;

_ble->subscribeToCharacteristic(deviceId, serviceUuid, characteristicUuid,
  [sink = _sink](const std::shared_ptr<ArrayBuffer>& value) {
    // On the manager's thread. The buffer is this value's own; it stays valid after returning.
    sink->push(value->data(), value->size());
  },
  [](const std::optional<BleError>& error) {
    // Once: after the CCCD write completed, or with the error (error->code, error->nativeStatus).
  });
```

**Callback rules.** A callback created in C++ runs directly on the manager's thread (Android: its HandlerThread; iOS: its CoreBluetooth queue), in the order the OS delivered the events, across all devices. JS callbacks hop to the JS thread instead; C++ ones never do.

- Return quickly and never block: every other BLE event of the manager waits behind your callback.
- No JSI in the callback: it is not on the JS thread. To reach JS, call a JS function your module received from Nitro (it hops to the JS thread).
- Asynchronous methods (`writeCharacteristic`, `subscribeToCharacteristic`, ...) may be called from a callback: they queue and run after the current callback returns, in call order.
- Synchronous methods (`isConnected`, `getServices`, ...) called from a callback run inline. Called from another thread, they wait for the manager's thread: never call one while holding a lock your callbacks take, and never block a callback waiting for a thread that calls one.
- Android: every call goes through JNI, so it must come from a thread attached to the JVM: the JS thread, the manager's thread (inside a callback), or a thread attached with `facebook::jni::ThreadScope`.

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
- `writeCharacteristic()` accepts an `ArrayBuffer` or a `number[]`, and resolves with an `ArrayBuffer` of the bytes written (was `number[]`). A write without response resolves when the OS accepted it, no longer at once (see [Flow control](#flow-control-writes-without-response)).
- The `subscribeToCharacteristic()` callback is `(data: ArrayBuffer) => void` (was `(characteristicId, data: number[])`).
- `AsyncSubscription.remove()` rejects when unsubscribing fails (1.x swallowed the error). The `remove()` of a subscription that a newer one to the same characteristic replaced does nothing.
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
  isBackgroundEnabled?: boolean;     // Enable background BLE support
  neverForLocation?: boolean;        // Assert no location derivation [Android 12+]
  modes?: ('peripheral' | 'central')[]; // iOS background modes
  bluetoothAlwaysPermission?: string | false; // iOS permission message
  androidAdvertisingEnabled?: boolean; // Android Peripheral mode (advertising)
  iOSLazyInit?: boolean;            // Lazy init BLE module to prevent permission dialog on app launch (delays state restoration)
}
```

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
  "modes": ["peripheral", "central"]
}
```

Adds these to `Info.plist`:
- `bluetooth-peripheral`: Act as BLE peripheral in background
- `bluetooth-central`: Scan/connect as central in background

### Android Permissions

Automatically adds required permissions and also handling neverForLocation and advertise mode.

```xml
<!-- Basic Bluetooth -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />

<!-- Location (required for BLE scanning) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- Android 12+ -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- BLE Hardware Feature -->
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
```

## Android Flow with Permission Handling

```ts
import { PermissionsAndroid, Platform } from 'react-native';

const requestPermissionsAndroid = async () => {
  if (Platform.OS !== 'android') {
    return true
  }
  if (Platform.OS === 'android' && PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION) {
    const apiLevel = parseInt(Platform.Version.toString(), 10);
    if (apiLevel < 31) {
      const result = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION);
      return (
        result === PermissionsAndroid.RESULTS.GRANTED
      );
    }
    if (PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN && PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT) {
      const result = await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION
      ])

      return (
        result['android.permission.BLUETOOTH_CONNECT'] === PermissionsAndroid.RESULTS.GRANTED &&
        result['android.permission.BLUETOOTH_SCAN'] === PermissionsAndroid.RESULTS.GRANTED &&
        result['android.permission.ACCESS_FINE_LOCATION'] === PermissionsAndroid.RESULTS.GRANTED
      )
    }

    logMessage('Request permissions failed');
    throw new Error('Request permissions failed');
  }
};

const hasPermissions = await requestPermissionsAndroid();

// Then start scanning or other operations
```

## 🔧 Development

### Building the Library

```bash
# Install dependencies
npm install

# Generate native Nitro code
npx nitro-codegen

# Build TypeScript
npm run build

# Run tests
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
│   ├── utils/             # Utility functions (UUID, Base64)
│   └── errors/            # BLE error handling
├── nitrogen/generated/     # Generated native code (Nitro)
├── plugin/                # Expo config plugin
├── ios/                   # iOS native implementation (Swift)
├── android/               # Android native implementation (Kotlin)
└── docs/                  # Documentation
```

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

### Development Setup

1. **Fork the repository** on GitHub
2. **Clone your fork**: `git clone https://github.com/YOUR_USERNAME/react-native-ble-nitro.git`
3. **Add upstream remote**: `git remote add upstream https://github.com/zykeco/react-native-ble-nitro.git`
4. **Install dependencies**: `npm install`
5. **Generate Nitro code**: `npx nitro-codegen`
6. **Make your changes** and run tests: `npm test`
7. **Submit a pull request**

## 📄 License

MIT License - see [LICENSE](./LICENSE) file.

## 🙏 Acknowledgments

- [Zyke Band](https://zykeband.com?utm_source=github&utm_medium=readme&utm_campaign=opensource) - The fitness tracker project that inspired this library
- [Marc Rousavy](https://github.com/mrousavy) - Creator of Nitro Modules and CEO of Margelo
- [Nitro Modules](https://nitro.margelo.com/) - High-performance native module framework
- [Margelo](https://margelo.com/) - Nitro Modules creators
- [Alvinotuya84](https://github.com/Alvinotuya84) - For the API inspiration I took from his repo [react-native-bluetooth-nitro-nexus](https://github.com/Alvinotuya84/react-native-bluetooth-nitro-nexus)

## 📞 Support

- 🐛 **Bug Reports**: [GitHub Issues](https://github.com/zykeco/react-native-ble-nitro/issues)
- 💬 **Questions**: [GitHub Discussions](https://github.com/zykeco/react-native-ble-nitro/discussions)
- 📖 **Documentation**: [API Reference](./docs/api.md)

---

**Made with ❤️ for the React Native community**
