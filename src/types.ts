/**
 * The public types of the JS API. Their native meaning is defined once, in
 * NativeBleNitro.nitro.ts; the docs here cover what the JS layer adds (string
 * enums, BleError, byte arrays) and point there for the rest.
 */
import type { BleError } from './BleError';

export type { CharacteristicProperties } from './specs/NativeBleNitro.nitro';

export type ByteArray = number[];

export interface ScanFilter {
  /** Only report devices advertising one of these services. Absent: all devices. */
  serviceUUIDs?: string[];
  /** Drop results weaker than this (dBm). Absent: no RSSI filter. */
  rssiThreshold?: number;
  /** Report every advertisement of a device, not only its first one. Default false. */
  allowDuplicates?: boolean;
  /** Android only. Default Balanced. */
  androidScanMode?: AndroidScanMode;
}

export interface ManufacturerDataEntry {
  id: string;
  data: ByteArray;
}

export interface ManufacturerData {
  companyIdentifiers: ManufacturerDataEntry[];
}

export interface ServiceDataEntry {
  uuid: string;
  data: ByteArray;
}

export interface ServiceData {
  services: ServiceDataEntry[];
}

/** A scanned or connected device. `id` is canonical (NativeBleNitro.nitro.ts, "Device ids"). */
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

export interface ConnectOptions {
  /** Android: BluetoothDevice.connectGatt's autoConnect. Default false. */
  autoConnectAndroid?: boolean;
  /** Android: clear the OS GATT cache right after the link comes up (ConnectOptions.refreshGatt in NativeBleNitro.nitro.ts). Default false. */
  refreshGattAndroid?: boolean;
  /** Connect timeout in milliseconds; see ConnectOptions.timeoutMs in NativeBleNitro.nitro.ts. */
  timeoutMs?: number;
}

export interface FindAndConnectOptions extends ConnectOptions {
  /** How long to scan for the device before failing with DeviceNotFound. Default 5000 ms. */
  scanTimeout?: number;
  /**
   * Scan only for devices advertising one of these services. Absent: all
   * devices. Pass the device's advertised service whenever it is known: an
   * unfiltered scan finds nothing in some states the app can't control.
   * Android pauses scans without a filter while the screen is off (the
   * BluetoothLeScanner.startScan documentation: "For unfiltered scans,
   * scanning is stopped on screen off to save power"), and iOS delivers
   * results to a background app only for scans for specific services (Core
   * Bluetooth Programming Guide, "Performing Long-Term Actions in the
   * Background").
   */
  serviceUUIDs?: string[];
  onDisconnect?: DisconnectEventCallback;
  /**
   * Called with the scan result once the device was found, as the connect
   * starts. It runs in the scan's callback: an exception it throws reaches
   * the global error handler, and the connect goes on.
   */
  onFound?: (device: BLEDevice) => void;
}

/** The connection event types; see ConnectionEventType in NativeBleNitro.nitro.ts for when each fires. */
export enum ConnectionEventType {
  Connected = 'Connected',
  Disconnected = 'Disconnected',
  ServicesChanged = 'ServicesChanged',
}

/** See ConnectionEvent in NativeBleNitro.nitro.ts; `error` is a BleError carrying `deviceId`. */
export interface ConnectionEvent {
  deviceId: string;
  type: ConnectionEventType;
  interrupted: boolean;
  error?: BleError;
}

export type ScanCallback = (device: BLEDevice) => void;
export type ScanErrorCallback = (error: BleError) => void;
export type RestoreStateCallback = (connectedPeripherals: BLEDevice[]) => void;
export type StateChangeCallback = (state: BLEState) => void;
/** See DisconnectionEventCallback in NativeBleNitro.nitro.ts; `error` is a BleError. */
export type DisconnectEventCallback = (deviceId: string, interrupted: boolean, error?: BleError) => void;
export type CharacteristicUpdateCallback = (data: ArrayBuffer) => void;
/** See SubscriptionEndedCallback in NativeBleNitro.nitro.ts; never called after remove() or destroy(). */
export type SubscriptionEndedCallback = (error: BleError) => void;
export type ConnectionEventCallback = (event: ConnectionEvent) => void;

/** remove() ends the subscription; calling it again does nothing. */
export type Subscription = {
  remove: () => void;
};

/** remove() ends the subscription; every call returns the same promise. */
export type AsyncSubscription = {
  remove: () => Promise<void>;
};

export enum BLEState {
  Unknown = 'Unknown',
  Resetting = 'Resetting',
  Unsupported = 'Unsupported',
  Unauthorized = 'Unauthorized',
  PoweredOff = 'PoweredOff',
  PoweredOn = 'PoweredOn',
}

export enum AndroidScanMode {
  LowLatency = 'LowLatency',
  Balanced = 'Balanced',
  LowPower = 'LowPower',
  Opportunistic = 'Opportunistic',
}

export enum AndroidConnectionPriority {
  Balanced = 'Balanced',
  High = 'High',
  LowPower = 'LowPower',
}

export type BleNitroManagerOptions = {
  /**
   * iOS: CoreBluetooth state-restoration key. Absent: no state restoration.
   * Keep it stable across releases; iOS restores by this key.
   */
  restoreIdentifier?: string;
  onRestoredState?: RestoreStateCallback;
};
