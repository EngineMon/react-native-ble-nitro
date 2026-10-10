import BleNitroNativeFactory from './specs/NativeBleNitroFactory';
import {
  AndroidConnectionPriority as NativeAndroidConnectionPriority,
  AndroidScanMode as NativeAndroidScanMode,
  BleErrorCode,
  BLEState as NativeBLEState,
  type BLEDevice as NativeBLEDevice,
  type BleError as NativeBleError,
  type ConnectOptions as NativeConnectOptions,
  type NativeBleNitro,
  type OperationCallback as NativeOperationCallback,
  type ScanFilter as NativeScanFilter,
} from './specs/NativeBleNitro.nitro';

export { BleErrorCode, type NativeBleNitro };

/**
 * The error every promise of this library rejects with, and every
 * synchronous method throws.
 */
export class BleError extends Error {
  /** What went wrong. The numbers equal react-native-ble-plx's BleErrorCode. */
  readonly errorCode: BleErrorCode;
  /**
   * The platform's own status when it gave one: Android GATT/HCI status or
   * scan error code, iOS CBError/CBATTError code.
   */
  readonly nativeStatus?: number;
  /** The device the failed operation was for, if any. */
  readonly deviceId?: string;
  /** The exception this error was converted from, if any. */
  readonly cause?: unknown;

  constructor(
    errorCode: BleErrorCode,
    message: string,
    details: { nativeStatus?: number; deviceId?: string; cause?: unknown } = {}
  ) {
    super(message);
    this.name = 'BleError';
    this.errorCode = errorCode;
    this.nativeStatus = details.nativeStatus;
    this.deviceId = details.deviceId;
    this.cause = details.cause;
  }
}

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
  /**
   * Android: clear the OS GATT cache (BluetoothGatt.refresh) right after the
   * link comes up, before any other operation. Default false.
   */
  refreshGattAndroid?: boolean;
  /**
   * Fail the connect with OperationTimedOut and cancel the pending link when
   * it isn't up after this long. Absent: the OS decides (Android about 30 s,
   * iOS never).
   */
  timeoutMs?: number;
}

export interface FindAndConnectOptions extends ConnectOptions {
  /** How long to scan for the device before failing with DeviceNotFound. Default 5000 ms. */
  scanTimeout?: number;
  onDisconnect?: DisconnectEventCallback;
  /** Called with the scan result once the device was found, as the connect starts. */
  onFound?: (device: BLEDevice) => void;
}

export type ScanCallback = (device: BLEDevice) => void;
export type ScanErrorCallback = (error: BleError) => void;
export type RestoreStateCallback = (connectedPeripherals: BLEDevice[]) => void;
export type StateChangeCallback = (state: BLEState) => void;
/**
 * `interrupted` is false when the link went down because of disconnect() or
 * destroy(), true when the device or the OS dropped it.
 */
export type DisconnectEventCallback = (
  deviceId: string,
  interrupted: boolean,
  error?: BleError
) => void;
export type CharacteristicUpdateCallback = (data: ArrayBuffer) => void;

export type Subscription = {
  remove: () => void;
};

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

const FIND_AND_CONNECT_SCAN_TIMEOUT_MS = 5000;

const BLE_STATE_FROM_NATIVE: Record<NativeBLEState, BLEState> = {
  [NativeBLEState.Unknown]: BLEState.Unknown,
  [NativeBLEState.Resetting]: BLEState.Resetting,
  [NativeBLEState.Unsupported]: BLEState.Unsupported,
  [NativeBLEState.Unauthorized]: BLEState.Unauthorized,
  [NativeBLEState.PoweredOff]: BLEState.PoweredOff,
  [NativeBLEState.PoweredOn]: BLEState.PoweredOn,
};

const SCAN_MODE_TO_NATIVE: Record<AndroidScanMode, NativeAndroidScanMode> = {
  [AndroidScanMode.LowLatency]: NativeAndroidScanMode.LowLatency,
  [AndroidScanMode.Balanced]: NativeAndroidScanMode.Balanced,
  [AndroidScanMode.LowPower]: NativeAndroidScanMode.LowPower,
  [AndroidScanMode.Opportunistic]: NativeAndroidScanMode.Opportunistic,
};

const CONNECTION_PRIORITY_TO_NATIVE: Record<AndroidConnectionPriority, NativeAndroidConnectionPriority> = {
  [AndroidConnectionPriority.Balanced]: NativeAndroidConnectionPriority.Balanced,
  [AndroidConnectionPriority.High]: NativeAndroidConnectionPriority.High,
  [AndroidConnectionPriority.LowPower]: NativeAndroidConnectionPriority.LowPower,
};

function bleErrorFromNative(error: NativeBleError, deviceId: string | undefined): BleError {
  return new BleError(error.code, error.message, { nativeStatus: error.nativeStatus, deviceId });
}

/** Wraps an exception a native call threw (a bug or an OS exception) into a BleError. */
function bleErrorFromThrown(thrown: unknown, deviceId: string | undefined): BleError {
  if (thrown instanceof BleError) return thrown;
  const message = thrown instanceof Error ? thrown.message : String(thrown);
  return new BleError(BleErrorCode.UnknownError, message, { deviceId, cause: thrown });
}

function toBleDevice(device: NativeBLEDevice): BLEDevice {
  return {
    id: device.id,
    name: device.name,
    rssi: device.rssi,
    isConnectable: device.isConnectable,
    isConnected: device.isConnected,
    serviceUUIDs: BleNitroManager.normalizeGattUUIDs(device.serviceUUIDs),
    manufacturerData: {
      companyIdentifiers: device.manufacturerData.companyIdentifiers.map((entry) => ({
        id: entry.id,
        data: Array.from(new Uint8Array(entry.data)),
      })),
    },
    serviceData: {
      services: device.serviceData.services.map((entry) => ({
        uuid: BleNitroManager.normalizeGattUUID(entry.uuid),
        data: Array.from(new Uint8Array(entry.data)),
      })),
    },
  };
}

type StateListener = { callback: StateChangeCallback };

/** Identity of one startScan call; results of a stopped or replaced scan are dropped. */
type ScanSession = object;

/**
 * One subscribeToCharacteristic call. The native side keeps one subscription
 * per characteristic, so a newer subscription (or an unsubscribe) deactivates
 * this one: it gets no more values and its remove() leaves the newer one alone.
 */
type NotificationSubscription = { active: boolean };

/**
 * Promise API over the native manager (see NativeBleNitro.nitro.ts for the
 * native contract).
 *
 * - Every promise settles exactly once and rejects with a BleError; every
 *   synchronous method throws BleError.
 * - Operations on one device run one at a time, in call order, natively.
 *   Every queued GATT operation fails with OperationTimedOut after 30 s.
 * - When a link drops, every pending operation of it fails with
 *   DeviceDisconnected; destroy() fails them with BluetoothManagerDestroyed.
 * - Callbacks run on the JS thread, in the order the OS delivered the events.
 * - After destroy(), every method throws or rejects with
 *   BluetoothManagerDestroyed, except the ones that only release something
 *   (stopScan, Subscription.remove, AsyncSubscription.remove, destroy), which
 *   do nothing.
 */
export class BleNitroManager {
  private readonly _native: NativeBleNitro;
  private _destroyed = false;

  private _restoredStateCallback: RestoreStateCallback | null;
  private _restoredState: BLEDevice[] | null = null;

  private _scanSession: ScanSession | null = null;
  private readonly _stateListeners = new Set<StateListener>();
  /** Keyed by device, service and characteristic; the newest subscription per characteristic. */
  private readonly _notificationSubscriptions = new Map<string, NotificationSubscription>();

  constructor(options?: BleNitroManagerOptions) {
    this._restoredStateCallback = options?.onRestoredState ?? null;
    this._native = BleNitroNativeFactory.create(options?.restoreIdentifier, (peripherals: NativeBLEDevice[]) =>
      this._onNativeRestoredState(peripherals)
    );
  }

  /**
   * The native manager (a Nitro HybridObject), for native modules that use it
   * from C++: pass it to a Nitro method taking a HybridObject and
   * `std::dynamic_pointer_cast<HybridNativeBleNitroSpec>` it there.
   */
  public get nativeObject(): NativeBleNitro {
    return this._native;
  }

  private _onNativeRestoredState(peripherals: NativeBLEDevice[]): void {
    const devices = peripherals.map(toBleDevice);
    if (this._restoredStateCallback) {
      this._restoredStateCallback(devices);
    } else {
      this._restoredState = [...(this._restoredState ?? []), ...devices];
    }
  }

  /**
   * Explicitly initializes BLE on iOS.
   * Call this to trigger the Bluetooth permission dialog at a specific moment
   * when using lazy iOS initialization.
   * No-op on Android.
   */
  public iosLazyInit(): void {
    this._sync(undefined, () => this._native.iosLazyInit());
  }

  /**
   * Sets the callback for iOS state restoration (the peripherals iOS kept
   * connected while the app was not running). Peripherals restored before a
   * callback was set are kept and passed to the first callback set, once.
   * Only works with a `restoreIdentifier` (not with the BleNitro singleton).
   */
  public onRestoredState(callback: RestoreStateCallback): void {
    this._restoredStateCallback = callback;
    const restored = this._restoredState;
    if (restored) {
      this._restoredState = null;
      callback(restored);
    }
  }

  /**
   * Converts a 16- or 32-bit UUID to a lowercase 128-bit UUID.
   *
   * @param uuid 16-, 32- or 128-bit UUID as string
   * @returns Full lowercase 128-bit UUID
   */
  public static normalizeGattUUID(uuid: string): string {
    const cleanUuid = uuid.toLowerCase();

    // Already a 128-bit UUID
    if (cleanUuid.length === 36 && cleanUuid.includes('-')) {
      return cleanUuid;
    }

    // 16- or 32-bit UUID on the Bluetooth base UUID
    const padded = cleanUuid.padStart(8, '0');
    return `${padded}-0000-1000-8000-00805f9b34fb`;
  }

  public static normalizeGattUUIDs(uuids: string[]): string[] {
    return uuids.map((uuid) => BleNitroManager.normalizeGattUUID(uuid));
  }

  /**
   * Starts scanning. Only one scan runs at a time: starting a scan stops the
   * previous one, whose callbacks are not called anymore.
   *
   * @param onError Called once if the scan fails to start or stops by itself;
   *   the scan is over then. Without it, such a failure is thrown from the
   *   native callback, i.e. it reaches the global error handler.
   */
  public startScan(filter: ScanFilter = {}, onDevice: ScanCallback, onError?: ScanErrorCallback): void {
    this._startScan(filter, onDevice, onError);
  }

  private _startScan(filter: ScanFilter, onDevice: ScanCallback, onError: ScanErrorCallback | undefined): ScanSession {
    this._assertAlive(undefined);
    const nativeFilter: NativeScanFilter = {
      serviceUUIDs: BleNitroManager.normalizeGattUUIDs(filter.serviceUUIDs ?? []),
      rssiThreshold: filter.rssiThreshold,
      allowDuplicates: filter.allowDuplicates ?? false,
      androidScanMode: SCAN_MODE_TO_NATIVE[filter.androidScanMode ?? AndroidScanMode.Balanced],
    };
    if (this._scanSession) {
      this._sync(undefined, () => this._native.stopScan());
    }
    const session: ScanSession = {};
    this._scanSession = session;
    this._sync(undefined, () =>
      this._native.startScan(nativeFilter, (device, error) => {
        if (this._scanSession !== session) return;
        if (error) {
          this._scanSession = null;
          const bleError = bleErrorFromNative(error, undefined);
          if (!onError) throw bleError;
          onError(bleError);
          return;
        }
        if (device) onDevice(toBleDevice(device));
      })
    );
    return session;
  }

  /** Stops the scan. No callback of it is called after this returns. */
  public stopScan(): void {
    if (this._destroyed) return;
    this._scanSession = null;
    this._sync(undefined, () => this._native.stopScan());
  }

  public isScanning(): boolean {
    return this._sync(undefined, () => this._native.isScanning());
  }

  /**
   * Devices connected to this phone (also by other apps), optionally only
   * those with one of the given services.
   */
  public getConnectedDevices(services?: string[]): BLEDevice[] {
    const serviceUUIDs = BleNitroManager.normalizeGattUUIDs(services ?? []);
    return this._sync(undefined, () => this._native.getConnectedDevices(serviceUUIDs)).map(toBleDevice);
  }

  /**
   * Connects to a device and resolves with its id once the link is up.
   *
   * Connecting to a device that is already connected (e.g. restored by iOS)
   * resolves and installs `onDisconnect`. While another connect to the device
   * is pending, rejects with DeviceAlreadyConnected. disconnect() cancels a
   * pending connect, which then rejects with OperationCancelled.
   *
   * @param onDisconnect Called once when this link goes down.
   */
  public connect(deviceId: string, options: ConnectOptions = {}, onDisconnect?: DisconnectEventCallback): Promise<string> {
    const nativeOptions: NativeConnectOptions = {
      autoConnect: options.autoConnectAndroid,
      refreshGatt: options.refreshGattAndroid,
      timeoutMs: options.timeoutMs,
    };
    const disconnectCallback = onDisconnect
      ? (id: string, interrupted: boolean, error: NativeBleError | undefined) =>
          onDisconnect(id, interrupted, error && bleErrorFromNative(error, id))
      : undefined;
    return this._operation(deviceId, (callback) =>
      this._native.connect(deviceId, nativeOptions, callback, disconnectCallback)
    ).then(() => deviceId);
  }

  /**
   * Scans for a device and connects to it. A device that is already connected
   * is connected to without scanning.
   *
   * Rejects with DeviceNotFound when the scan doesn't find the device within
   * `scanTimeout`, or with the scan's or the connect's error. Starting another
   * scan meanwhile stops this one.
   */
  public async findAndConnect(deviceId: string, options: FindAndConnectOptions = {}): Promise<string> {
    const { scanTimeout = FIND_AND_CONNECT_SCAN_TIMEOUT_MS, onDisconnect, onFound, ...connectOptions } = options;
    if (this.isConnected(deviceId)) {
      return this.connect(deviceId, connectOptions, onDisconnect);
    }
    return new Promise<string>((resolve, reject) => {
      const session = this._startScan(
        {},
        (device) => {
          if (device.id !== deviceId) return;
          clearTimeout(timer);
          this.stopScan();
          this.connect(deviceId, connectOptions, onDisconnect).then(resolve, reject);
          onFound?.(device);
        },
        (error) => {
          clearTimeout(timer);
          reject(error);
        }
      );
      const timer = setTimeout(() => {
        if (this._scanSession === session) this.stopScan();
        reject(
          new BleError(BleErrorCode.DeviceNotFound, `Device ${deviceId} not found within ${scanTimeout} ms of scanning`, {
            deviceId,
          })
        );
      }, scanTimeout);
    });
  }

  /**
   * Disconnects from a device, or cancels a pending connect to it. Resolves
   * once the link is down. Always goes to the native side, whatever
   * isConnected() says; rejects with DeviceNotConnected when there is neither
   * a link nor a pending connect.
   */
  public disconnect(deviceId: string): Promise<void> {
    return this._operation(deviceId, (callback) => this._native.disconnect(deviceId, callback));
  }

  public isConnected(deviceId: string): boolean {
    return this._sync(deviceId, () => this._native.isConnected(deviceId));
  }

  /**
   * Requests an ATT MTU and resolves with the ATT MTU in effect: on Android
   * the negotiated one, on iOS the one CoreBluetooth negotiated by itself
   * (iOS ignores the requested value).
   * @param mtu Requested ATT MTU, 23 to 517
   */
  public requestMTU(deviceId: string, mtu: number): Promise<number> {
    return this._request<number>(deviceId, (callback) => this._native.requestMTU(deviceId, mtu, callback));
  }

  /**
   * Requests an Android connection priority. Resolves when Android accepted
   * the request (the change itself applies asynchronously); resolves at once
   * on iOS.
   */
  public requestConnectionPriority(deviceId: string, priority: AndroidConnectionPriority): Promise<void> {
    const nativePriority = CONNECTION_PRIORITY_TO_NATIVE[priority];
    return this._operation(deviceId, (callback) =>
      this._native.requestConnectionPriority(deviceId, nativePriority, callback)
    );
  }

  public readRSSI(deviceId: string): Promise<number> {
    return this._request<number>(deviceId, (callback) => this._native.readRSSI(deviceId, callback));
  }

  /** Discovers the device's services. */
  public discoverServices(deviceId: string): Promise<void> {
    return this._operation(deviceId, (callback) => this._native.discoverServices(deviceId, callback));
  }

  /** Discovers the services and resolves with their lowercase 128-bit UUIDs. */
  public async getServices(deviceId: string): Promise<string[]> {
    await this.discoverServices(deviceId);
    return BleNitroManager.normalizeGattUUIDs(this._sync(deviceId, () => this._native.getServices(deviceId)));
  }

  /**
   * The lowercase 128-bit UUIDs of a discovered service's characteristics.
   * Needs a completed discovery (getServicesWithCharacteristics).
   */
  public getCharacteristics(deviceId: string, serviceId: string): string[] {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    return BleNitroManager.normalizeGattUUIDs(this._sync(deviceId, () => this._native.getCharacteristics(deviceId, service)));
  }

  /**
   * Discovers all services and their characteristics and resolves with their
   * lowercase 128-bit UUIDs. Resolves only after characteristic discovery
   * completed, avoiding the CoreBluetooth race where didDiscoverServices may
   * not fire again for cached services.
   */
  public async getServicesWithCharacteristics(
    deviceId: string
  ): Promise<{ uuid: string; characteristics: string[] }[]> {
    await this._operation(deviceId, (callback) =>
      this._native.discoverServicesWithCharacteristics(deviceId, callback)
    );
    const services = BleNitroManager.normalizeGattUUIDs(this._sync(deviceId, () => this._native.getServices(deviceId)));
    return services.map((service) => ({
      uuid: service,
      characteristics: this.getCharacteristics(deviceId, service),
    }));
  }

  public readCharacteristic(deviceId: string, serviceId: string, characteristicId: string): Promise<ArrayBuffer> {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    const characteristic = BleNitroManager.normalizeGattUUID(characteristicId);
    return this._request<ArrayBuffer>(deviceId, (callback) =>
      this._native.readCharacteristic(deviceId, service, characteristic, callback)
    );
  }

  /**
   * Writes a characteristic and resolves with the bytes written (both write
   * types).
   *
   * A write without response resolves when the OS accepted it for sending
   * (Android onCharacteristicWrite, iOS canSendWriteWithoutResponse), so
   * awaiting each write paces a burst instead of overflowing the OS buffers.
   * The bytes are copied during the call; `data` may be reused right after.
   *
   * @param data The bytes. A number[] is converted once, an ArrayBuffer is passed as is.
   */
  public writeCharacteristic(
    deviceId: string,
    serviceId: string,
    characteristicId: string,
    data: ArrayBuffer | ByteArray,
    withResponse: boolean = true
  ): Promise<ArrayBuffer> {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    const characteristic = BleNitroManager.normalizeGattUUID(characteristicId);
    const buffer = Array.isArray(data) ? new Uint8Array(data).buffer : data;
    return this._request<ArrayBuffer>(deviceId, (callback) =>
      this._native.writeCharacteristic(deviceId, service, characteristic, buffer, withResponse, callback)
    );
  }

  /**
   * Enables notifications (or indications) of a characteristic and resolves
   * once the device acknowledged it (CCCD written). `onValue` gets each
   * value's bytes as an ArrayBuffer of its own.
   *
   * There is one subscription per characteristic: subscribing again replaces
   * the previous one, which then gets no more values and whose remove() does
   * nothing. remove() rejects if the unsubscribe fails.
   */
  public subscribeToCharacteristic(
    deviceId: string,
    serviceId: string,
    characteristicId: string,
    onValue: CharacteristicUpdateCallback
  ): Promise<AsyncSubscription> {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    const characteristic = BleNitroManager.normalizeGattUUID(characteristicId);
    const subscription: NotificationSubscription = { active: true };
    return this._operation(deviceId, (callback) => {
      this._native.subscribeToCharacteristic(
        deviceId,
        service,
        characteristic,
        (data) => {
          if (subscription.active) onValue(data);
        },
        (error) => {
          // Native keeps the previous subscription when a replacement fails,
          // so it stays active until one succeeds.
          if (!error) this._replaceNotificationSubscription(deviceId, service, characteristic, subscription);
          callback(error);
        }
      );
    }).then(() => ({
      remove: () =>
        subscription.active
          ? this.unsubscribeFromCharacteristic(deviceId, service, characteristic)
          : Promise.resolve(),
    }));
  }

  /** Disables notifications of a characteristic; its subscription gets no more values. */
  public unsubscribeFromCharacteristic(deviceId: string, serviceId: string, characteristicId: string): Promise<void> {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    const characteristic = BleNitroManager.normalizeGattUUID(characteristicId);
    return this._operation(deviceId, (callback) => {
      this._native.unsubscribeFromCharacteristic(deviceId, service, characteristic, callback);
      this._replaceNotificationSubscription(deviceId, service, characteristic, null);
    });
  }

  private _replaceNotificationSubscription(
    deviceId: string,
    service: string,
    characteristic: string,
    subscription: NotificationSubscription | null
  ): void {
    const key = `${deviceId}|${service}|${characteristic}`;
    const previous = this._notificationSubscriptions.get(key);
    if (previous) previous.active = false;
    if (subscription) {
      this._notificationSubscriptions.set(key, subscription);
    } else {
      this._notificationSubscriptions.delete(key);
    }
  }

  /** False for disconnected or unknown devices. */
  public isSubscribedToCharacteristic(deviceId: string, serviceId: string, characteristicId: string): boolean {
    const service = BleNitroManager.normalizeGattUUID(serviceId);
    const characteristic = BleNitroManager.normalizeGattUUID(characteristicId);
    return this._sync(deviceId, () => this._native.isSubscribedToCharacteristic(deviceId, service, characteristic));
  }

  public isBluetoothEnabled(): boolean {
    return this.state() === BLEState.PoweredOn;
  }

  /**
   * Android: asks the user to turn Bluetooth on. Rejects with
   * BluetoothStateChangeFailed on iOS, which doesn't allow it.
   */
  public requestBluetoothEnable(): Promise<void> {
    return this._operation(undefined, (callback) => this._native.requestBluetoothEnable(callback));
  }

  public state(): BLEState {
    return BLE_STATE_FROM_NATIVE[this._sync(undefined, () => this._native.state())];
  }

  /**
   * Calls `callback` on every Bluetooth state change. Any number of
   * subscriptions may exist; remove() removes only its own.
   * @param emitInitial Also call `callback` with the current state right away.
   */
  public subscribeToStateChange(callback: StateChangeCallback, emitInitial = false): Subscription {
    this._assertAlive(undefined);
    if (this._stateListeners.size === 0) {
      const result = this._sync(undefined, () =>
        this._native.subscribeToStateChange((nativeState) => this._dispatchState(BLE_STATE_FROM_NATIVE[nativeState]))
      );
      if (!result.success) {
        throw new BleError(BleErrorCode.UnknownError, `Could not subscribe to Bluetooth state changes: ${result.error}`);
      }
    }
    const listener: StateListener = { callback };
    this._stateListeners.add(listener);
    const subscription: Subscription = { remove: () => this._removeStateListener(listener) };
    if (emitInitial) {
      try {
        callback(this.state());
      } catch (error) {
        subscription.remove();
        throw error;
      }
    }
    return subscription;
  }

  private _dispatchState(state: BLEState): void {
    for (const listener of Array.from(this._stateListeners)) {
      // A listener removed by an earlier one during this dispatch gets nothing.
      if (!this._stateListeners.has(listener)) continue;
      try {
        listener.callback(state);
      } catch (error) {
        // Rethrown outside this loop so the error reaches the global error
        // handler and one listener's bug doesn't keep the state from the others.
        setTimeout(() => {
          throw error;
        }, 0);
      }
    }
  }

  private _removeStateListener(listener: StateListener): void {
    if (!this._stateListeners.delete(listener) || this._stateListeners.size > 0) return;
    const result = this._sync(undefined, () => this._native.unsubscribeFromStateChange());
    if (!result.success) {
      throw new BleError(BleErrorCode.UnknownError, `Could not unsubscribe from Bluetooth state changes: ${result.error}`);
    }
  }

  /** Opens the system's Bluetooth settings. */
  public openSettings(): Promise<void> {
    return this._settle<void>(undefined, (resolve, reject) => {
      this._native.openSettings().then(resolve, (thrown: unknown) => reject(bleErrorFromThrown(thrown, undefined)));
    });
  }

  /**
   * Stops scanning, closes every link, fails every pending operation with
   * BluetoothManagerDestroyed and releases the OS resources. No callback is
   * called afterwards (except those failing pending operations). Idempotent.
   */
  public destroy(): void {
    if (this._destroyed) return;
    this._destroyed = true;
    this._scanSession = null;
    this._stateListeners.clear();
    for (const subscription of this._notificationSubscriptions.values()) subscription.active = false;
    this._notificationSubscriptions.clear();
    this._restoredStateCallback = null;
    this._restoredState = null;
    try {
      this._native.destroy();
    } catch (thrown) {
      throw bleErrorFromThrown(thrown, undefined);
    }
  }

  private _assertAlive(deviceId: string | undefined): void {
    if (this._destroyed) {
      throw new BleError(BleErrorCode.BluetoothManagerDestroyed, 'The BleNitroManager was destroyed', { deviceId });
    }
  }

  /** Runs a synchronous native call; anything it throws becomes a BleError. */
  private _sync<T>(deviceId: string | undefined, call: () => T): T {
    this._assertAlive(deviceId);
    try {
      return call();
    } catch (thrown) {
      throw bleErrorFromThrown(thrown, deviceId);
    }
  }

  /**
   * The promise of one native operation. `start` issues it; whatever it
   * throws rejects the promise.
   */
  private _settle<T>(
    deviceId: string | undefined,
    start: (resolve: (value: T) => void, reject: (error: BleError) => void) => void
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      try {
        this._assertAlive(deviceId);
        start(resolve, reject);
      } catch (thrown) {
        reject(bleErrorFromThrown(thrown, deviceId));
      }
    });
  }

  /** An operation that completes with an error or nothing. */
  private _operation(deviceId: string | undefined, start: (callback: NativeOperationCallback) => void): Promise<void> {
    return this._settle<void>(deviceId, (resolve, reject) =>
      start((error) => (error ? reject(bleErrorFromNative(error, deviceId)) : resolve()))
    );
  }

  /** An operation that completes with an error or a result. */
  private _request<T>(
    deviceId: string | undefined,
    start: (callback: (error: NativeBleError | undefined, result: T | undefined) => void) => void
  ): Promise<T> {
    return this._settle<T>(deviceId, (resolve, reject) =>
      start((error, result) => {
        if (error) {
          reject(bleErrorFromNative(error, deviceId));
        } else if (result === undefined) {
          reject(new BleError(BleErrorCode.UnknownError, 'The native operation completed without a result', { deviceId }));
        } else {
          resolve(result);
        }
      })
    );
  }
}
