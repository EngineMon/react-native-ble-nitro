import { HybridObject } from 'react-native-nitro-modules';

// Type alias for BLE data - ArrayBuffers for efficient binary data handling
export type BLEValue = ArrayBuffer;

// Nitro constraint: Use numeric enums instead of string unions
export enum BLEState {
  Unknown = 0,
  Resetting = 1,
  Unsupported = 2,
  Unauthorized = 3,
  PoweredOff = 4,
  PoweredOn = 5,
}

export interface ManufacturerDataEntry {
  id: string;
  data: BLEValue;
}

export interface ManufacturerData {
  companyIdentifiers: ManufacturerDataEntry[];
}

export interface ServiceDataEntry {
  uuid: string;
  data: BLEValue;
}

export interface ServiceData {
  services: ServiceDataEntry[];
}

export interface BLEDevice {
  id: string;
  name: string;
  rssi: number;
  manufacturerData: ManufacturerData;
  serviceData: ServiceData;
  serviceUUIDs: string[];
  isConnectable: boolean;
  isConnected: boolean;
}

export enum AndroidScanMode {
  LowLatency = 0,
  Balanced = 1,
  LowPower = 2,
  Opportunistic = 3,
}

export enum AndroidConnectionPriority {
  Balanced = 0,
  High = 1,
  LowPower = 2,
}

/**
 * Error codes. The values match react-native-ble-plx's BleErrorCode, so code
 * written against it ports by name and by number.
 */
export enum BleErrorCode {
  UnknownError = 0,
  BluetoothManagerDestroyed = 1,
  OperationCancelled = 2,
  OperationTimedOut = 3,
  OperationStartFailed = 4,
  InvalidIdentifiers = 5,

  BluetoothUnsupported = 100,
  BluetoothUnauthorized = 101,
  BluetoothPoweredOff = 102,
  BluetoothInUnknownState = 103,
  BluetoothResetting = 104,
  BluetoothStateChangeFailed = 105,

  DeviceConnectionFailed = 200,
  DeviceDisconnected = 201,
  DeviceRSSIReadFailed = 202,
  DeviceAlreadyConnected = 203,
  DeviceNotFound = 204,
  DeviceNotConnected = 205,
  DeviceMTUChangeFailed = 206,

  ServicesDiscoveryFailed = 300,
  IncludedServicesDiscoveryFailed = 301,
  ServiceNotFound = 302,
  ServicesNotDiscovered = 303,

  CharacteristicsDiscoveryFailed = 400,
  CharacteristicWriteFailed = 401,
  CharacteristicReadFailed = 402,
  CharacteristicNotifyChangeFailed = 403,
  CharacteristicNotFound = 404,
  CharacteristicsNotDiscovered = 405,
  CharacteristicInvalidDataFormat = 406,

  DescriptorWriteFailed = 501,
  DescriptorReadFailed = 502,

  ScanStartFailed = 600,
  LocationServicesDisabled = 601,
}

export interface BleError {
  code: BleErrorCode;
  /** English, for logs. Not localized, not part of the contract. */
  message: string;
  /**
   * The platform's own status when it gave one: Android GATT/HCI status
   * (e.g. 133, 8, 19) or scan error code, iOS CBError/CBATTError code.
   */
  nativeStatus?: number;
}

export interface ConnectOptions {
  /** Android: BluetoothDevice.connectGatt's autoConnect. Default false. */
  autoConnect?: boolean;
  /**
   * Android: clear the OS GATT cache (BluetoothGatt.refresh) right after the
   * link comes up, before any other operation. Default false.
   */
  refreshGatt?: boolean;
  /**
   * Fails the connect with OperationTimedOut and cancels the pending link
   * when it isn't up after this long. Absent: the OS decides (Android about
   * 30 s, iOS never).
   */
  timeoutMs?: number;
}

export interface ScanFilter {
  serviceUUIDs: string[];
  /** Results weaker than this are dropped. Absent: no RSSI filter. */
  rssiThreshold?: number;
  /** Report every advertisement of a device, not only its first one. */
  allowDuplicates: boolean;
  androidScanMode: AndroidScanMode;
}

// Every asynchronous operation completes exactly once: with no error, or with
// one. Results are present exactly when there is no error.
export type OperationCallback = (error: BleError | undefined) => void;
export type ScanCallback = (device: BLEDevice | undefined, error: BleError | undefined) => void;
export type DisconnectionEventCallback = (deviceId: string, interrupted: boolean, error: BleError | undefined) => void;
export type NotificationCallback = (data: BLEValue) => void;
export type StateCallback = (state: BLEState) => void;
export type ReadCharacteristicCallback = (error: BleError | undefined, data: BLEValue | undefined) => void;
export type WriteCharacteristicCallback = (error: BleError | undefined, responseData: BLEValue | undefined) => void;
export type ReadRSSICallback = (error: BleError | undefined, rssi: number | undefined) => void;
export type MtuCallback = (error: BleError | undefined, mtu: number | undefined) => void;
export type RestoreCallback = (restoredPeripherals: BLEDevice[]) => void;

export type OperationResult = {
  success: boolean;
  error?: string;
};

/**
 * Native BLE Nitro Module Specification
 * Defines the interface between TypeScript and native implementations
 *
 * Threading: every callback is invoked from one serial queue per manager
 * (Android: a dedicated HandlerThread that also receives every
 * BluetoothGattCallback; iOS: the CBCentralManager's dedicated serial
 * DispatchQueue), in the order the OS delivered the events, across all
 * devices and characteristics. Callbacks created in JS hop to the JS thread
 * (Nitro); callbacks created in C++ by another native module run directly on
 * that queue and must not block it.
 *
 * Operations on one device run one at a time, in call order (Android's GATT
 * allows one outstanding operation per connection). A write without response
 * completes when the OS accepted it for sending (Android onCharacteristicWrite,
 * iOS canSendWriteWithoutResponse), so awaiting each write paces a burst.
 * When a link drops or the manager is destroyed, every pending operation of it
 * fails with DeviceDisconnected or BluetoothManagerDestroyed.
 */
export interface NativeBleNitro extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  // ios only
  restoreStateIdentifier?: string;
  setRestoreStateCallback(callback: RestoreCallback): void;
  iosLazyInit(): void;

  // Scanning operations. Failures to start or run a scan are reported through
  // the callback (device undefined), never thrown.
  startScan(filter: ScanFilter, callback: ScanCallback): void;
  stopScan(): boolean;
  isScanning(): boolean;

  // Device discovery
  getConnectedDevices(services: string[]): BLEDevice[];

  // Connection management. connect on a device that is already connected
  // (e.g. restored by iOS) succeeds and installs the new disconnect callback.
  // disconnect also cancels a connect that is still pending (which then fails
  // with OperationCancelled), and completes once the link is down.
  connect(deviceId: string, options: ConnectOptions, callback: OperationCallback, disconnectCallback?: DisconnectionEventCallback): void;
  disconnect(deviceId: string, callback: OperationCallback): void;
  isConnected(deviceId: string): boolean;
  /**
   * Completes with the ATT MTU in effect: on Android the value negotiated
   * (onMtuChanged), on iOS the one CoreBluetooth negotiated by itself
   * (maximumWriteValueLength(.withoutResponse) + 3).
   */
  requestMTU(deviceId: string, mtu: number, callback: MtuCallback): void;
  /** Android only; completes at once without error elsewhere. */
  requestConnectionPriority(deviceId: string, androidConnectionPriority: AndroidConnectionPriority, callback: OperationCallback): void;
  readRSSI(deviceId: string, callback: ReadRSSICallback): void;

  // Service discovery
  discoverServices(deviceId: string, callback: OperationCallback): void;
  /** Discover services and wait for all characteristic discovery to complete before resolving. */
  discoverServicesWithCharacteristics(deviceId: string, callback: OperationCallback): void;
  getServices(deviceId: string): string[];
  getCharacteristics(deviceId: string, serviceId: string): string[];

  // Characteristic operations
  readCharacteristic(deviceId: string, serviceId: string, characteristicId: string, callback: ReadCharacteristicCallback): void;
  writeCharacteristic(deviceId: string, serviceId: string, characteristicId: string, data: BLEValue, withResponse: boolean, callback: WriteCharacteristicCallback): void;
  /**
   * One subscription per characteristic: subscribing again replaces the
   * previous update callback. Each notification's bytes are a buffer of their
   * own, valid after the callback returns.
   */
  subscribeToCharacteristic(deviceId: string, serviceId: string, characteristicId: string, updateCallback: NotificationCallback, completionCallback: OperationCallback): void;
  unsubscribeFromCharacteristic(deviceId: string, serviceId: string, characteristicId: string, callback: OperationCallback): void;
  isSubscribedToCharacteristic(deviceId: string, serviceId: string, characteristicId: string): boolean;

  // Bluetooth state management
  requestBluetoothEnable(callback: OperationCallback): void;
  state(): BLEState;
  subscribeToStateChange(stateCallback: StateCallback): OperationResult;
  unsubscribeFromStateChange(): OperationResult;
  openSettings(): Promise<void>;

  /**
   * Stops scanning, closes every link, fails every pending operation with
   * BluetoothManagerDestroyed and releases the OS resources. The manager is
   * unusable afterwards.
   */
  destroy(): void;
}
