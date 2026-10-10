import BleNitroNativeFactory from './specs/NativeBleNitroFactory';
import {
  type BLEDevice as NativeBLEDevice,
  type BleError as NativeBleError,
  type NativeBleNitro,
  type OperationCallback as NativeOperationCallback,
  type ScanFilter as NativeScanFilter,
} from './specs/NativeBleNitro.nitro';
import { BleError, BleErrorCode, bleErrorFromNative, bleErrorFromThrown, destroyedError } from './BleError';
import { reportedGattUUID, requireGattUUID } from './gattUuid';
import {
  BLE_STATE_FROM_NATIVE,
  CONNECTION_PRIORITY_TO_NATIVE,
  SCAN_MODE_TO_NATIVE,
  canonicalDeviceId,
  toBleDevice,
  toConnectionEvent,
  toWriteBuffer,
} from './nativeConversions';
import { Registration, RegistrationSet } from './RegistrationSet';
import {
  AndroidScanMode,
  BLEState,
  type AndroidConnectionPriority,
  type AsyncSubscription,
  type BLEDevice,
  type BleNitroManagerOptions,
  type ByteArray,
  type CharacteristicProperties,
  type CharacteristicUpdateCallback,
  type ConnectionEventCallback,
  type ConnectOptions,
  type DisconnectEventCallback,
  type FindAndConnectOptions,
  type RestoreStateCallback,
  type ScanCallback,
  type ScanErrorCallback,
  type ScanFilter,
  type StateChangeCallback,
  type Subscription,
  type SubscriptionEndedCallback,
} from './types';

export * from './types';
export { BleError, BleErrorCode, type NativeBleNitro };

const FIND_AND_CONNECT_SCAN_TIMEOUT_MS = 5000;

/**
 * Identity of one startScan call; results of a scan that ended are dropped.
 * `onCancelled` learns why when something other than the scan itself ended
 * it (stopScan(), a newer scan, destroy()), so findAndConnect fails at once
 * instead of at its timeout. A scan that fails by itself reports to its error
 * callback instead.
 */
type ScanSession = { readonly onCancelled: ((error: BleError) => void) | null };

/** The settling side of one operation's promise (see BleNitroManager._settle). */
type Settlement<T> = {
  /** The canonical id of the operation's device, if any. */
  readonly deviceId: string | undefined;
  /** Resolves; after destroy() rejects with BluetoothManagerDestroyed instead. */
  resolve(value: T): void;
  /** Rejects with what the native side reported. */
  fail(error: NativeBleError): void;
  /** Rejects with anything thrown or rejected along the way, as a BleError. */
  reject(reason: unknown): void;
};

/**
 * Promise API over the native manager. The native behavior (threading,
 * device ids, operation order and lookup errors, timeouts, link loss, after
 * destroy()) is specified once, in NativeBleNitro.nitro.ts; this class adds:
 *
 * - Promises and BleError: every promise settles exactly once and rejects
 *   with a BleError; every synchronous method throws BleError. A method
 *   returning a promise never throws: invalid input (a malformed UUID, write
 *   data that isn't bytes, a missing options object) rejects its promise.
 * - Strict GATT UUIDs (see normalizeGattUUID); UUIDs come back in their
 *   lowercase 128-bit form.
 * - Canonical device ids: connect() and findAndConnect() resolve with the
 *   canonical id, and BleError.deviceId carries it, like every id the native
 *   side reports.
 * - Callbacks run on the JS thread, in the order the OS delivered the events.
 * - destroy() is a gate: from the moment it is called, no listener (scan,
 *   value, onEnded, state, connection event, disconnect, restored state) is
 *   called, also not for events the native side sent before (they reach the
 *   JS thread later), and no promise resolves: one whose native success was
 *   already on its way rejects with BluetoothManagerDestroyed, like every
 *   completion the native side fires after destroy(). Every later call
 *   throws or rejects with BluetoothManagerDestroyed, except those that only
 *   release something (stopScan, Subscription.remove,
 *   AsyncSubscription.remove, destroy), which do nothing.
 */
export class BleNitroManager {
  private readonly _native: NativeBleNitro;
  private _destroyed = false;

  private _restoredStateCallback: RestoreStateCallback | null;
  private _restoredState: BLEDevice[] | null = null;

  private _scanSession: ScanSession | null = null;
  private readonly _registrations = new RegistrationSet();

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

  /** The native side reports restored peripherals at most once per manager. */
  private _onNativeRestoredState(peripherals: NativeBLEDevice[]): void {
    if (this._destroyed) return;
    const devices = peripherals.map(toBleDevice);
    if (this._restoredStateCallback) {
      this._restoredStateCallback(devices);
    } else {
      this._restoredState = devices;
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
   * Converts a GATT UUID to its lowercase 128-bit (36-character) form.
   *
   * Accepts exactly, in any case: 4 or 8 hex digits (a 16- or 32-bit UUID,
   * placed on the Bluetooth Base UUID 00000000-0000-1000-8000-00805F9B34FB,
   * Bluetooth Core Specification Vol 3 Part B §2.5.1), 32 hex digits, and the
   * 8-4-4-4-12 form. Anything else throws BleError InvalidIdentifiers:
   * padding or passing on a malformed UUID would address another attribute
   * than the caller meant, or fail differently on each platform. Every method
   * taking a UUID parses it this way; a method returning a promise rejects
   * instead of throwing.
   *
   * @returns The lowercase 128-bit UUID
   */
  public static normalizeGattUUID(uuid: string): string {
    return requireGattUUID(uuid);
  }

  /** normalizeGattUUID for each UUID. */
  public static normalizeGattUUIDs(uuids: string[]): string[] {
    return uuids.map(requireGattUUID);
  }

  /**
   * Starts scanning. Only one scan runs at a time: starting a scan always
   * stops the previous one first, whose callbacks are not called anymore.
   * Only an invalid filter throws before that, leaving a running scan
   * untouched. A start that fails afterwards, also before reaching the OS
   * (Android's scan-start throttle), reports to this scan's onError; the
   * previous scan is over by then. (The native startScan keeps a running
   * scan on such a failure; this method has already stopped it.)
   *
   * @param onError Called once if the scan fails to start or stops by itself;
   *   the scan is over then. Without it, such a failure is thrown from the
   *   native callback, i.e. it reaches the global error handler.
   */
  public startScan(filter: ScanFilter = {}, onDevice: ScanCallback, onError?: ScanErrorCallback): void {
    this._startScan(filter, onDevice, onError, null);
  }

  private _startScan(
    filter: ScanFilter,
    onDevice: ScanCallback,
    onError: ScanErrorCallback | undefined,
    onCancelled: ScanSession['onCancelled']
  ): ScanSession {
    return this._sync(undefined, () => {
      // Built before anything is stopped, so an invalid filter throws with the
      // running scan untouched.
      const nativeFilter: NativeScanFilter = {
        serviceUUIDs: BleNitroManager.normalizeGattUUIDs(filter.serviceUUIDs ?? []),
        rssiThreshold: filter.rssiThreshold,
        allowDuplicates: filter.allowDuplicates ?? false,
        androidScanMode: SCAN_MODE_TO_NATIVE[filter.androidScanMode ?? AndroidScanMode.Balanced],
      };
      const previous = this._scanSession;
      if (previous) {
        this._stopScanSession(
          previous,
          new BleError(BleErrorCode.OperationCancelled, 'The scan was replaced by a newer one')
        );
      }
      const session: ScanSession = { onCancelled };
      this._scanSession = session;
      try {
        this._native.startScan(nativeFilter, (device, error) => {
          if (this._scanSession !== session) return;
          if (error) {
            this._endScanSession(session, null);
            const bleError = bleErrorFromNative(error, undefined);
            if (!onError) throw bleError;
            onError(bleError);
            return;
          }
          if (device) onDevice(toBleDevice(device));
        });
      } catch (thrown) {
        // No scan was started; a later startScan or stopScan must not treat this one as running.
        this._endScanSession(session, null);
        throw thrown;
      }
      return session;
    });
  }

  /**
   * Ends `session` if it is the current scan: its later results are dropped,
   * and its owner learns `cancellation` (null: the owner ended it itself, or
   * it failed by itself). False when it had ended already.
   */
  private _endScanSession(session: ScanSession, cancellation: BleError | null): boolean {
    if (this._scanSession !== session) return false;
    this._scanSession = null;
    if (cancellation) session.onCancelled?.(cancellation);
    return true;
  }

  /**
   * Ends `session` and stops the native scan, only if it is still the current
   * scan: an owner stopping its own scan late never stops a newer one.
   */
  private _stopScanSession(session: ScanSession, cancellation: BleError | null): void {
    if (this._endScanSession(session, cancellation)) {
      this._sync(undefined, () => this._native.stopScan());
    }
  }

  /** Stops the scan. No callback of it is called after this returns. */
  public stopScan(): void {
    if (this._destroyed) return;
    const session = this._scanSession;
    if (session) this._endScanSession(session, new BleError(BleErrorCode.OperationCancelled, 'The scan was stopped'));
    // Also without a session of this object: the native manager has one scan,
    // which C++ sharing it may have started.
    this._sync(undefined, () => this._native.stopScan());
  }

  public isScanning(): boolean {
    return this._sync(undefined, () => this._native.isScanning());
  }

  /** See getConnectedDevices in NativeBleNitro.nitro.ts. */
  public getConnectedDevices(services?: string[]): BLEDevice[] {
    return this._sync(undefined, () =>
      this._native.getConnectedDevices(BleNitroManager.normalizeGattUUIDs(services ?? []))
    ).map(toBleDevice);
  }

  /**
   * Connects to a device and resolves with its canonical id once the link is
   * up. See connect in NativeBleNitro.nitro.ts (already connected, pending
   * connects, cancellation by disconnect()).
   *
   * @param onDisconnect Called once when this link goes down.
   */
  public connect(deviceId: string, options?: ConnectOptions, onDisconnect?: DisconnectEventCallback): Promise<string> {
    return this._settle<string>(deviceId, (settlement) => {
      const disconnectCallback = onDisconnect
        ? (id: string, interrupted: boolean, error: NativeBleError | undefined) => {
            // A link that went down before destroy() may report it after (the
            // report reaches the JS thread later); no listener runs after destroy().
            if (this._destroyed) return;
            onDisconnect(id, interrupted, error && bleErrorFromNative(error, id));
          }
        : undefined;
      this._native.connect(
        deviceId,
        {
          autoConnect: options?.autoConnectAndroid,
          refreshGatt: options?.refreshGattAndroid,
          timeoutMs: options?.timeoutMs,
        },
        (error) => (error ? settlement.fail(error) : settlement.resolve(canonicalDeviceId(deviceId))),
        disconnectCallback
      );
    });
  }

  /**
   * Scans for a device and connects to it; resolves with its canonical id. A
   * device that is already connected is connected to without scanning.
   *
   * The scan replaces any running scan (whose callbacks are not called
   * anymore). Device ids are compared in their canonical (uppercase) form, so
   * the case of `deviceId` doesn't matter.
   *
   * Rejects with DeviceNotFound when the scan doesn't find the device within
   * `scanTimeout`, or with the scan's or the connect's error. When a newer
   * scan or stopScan() ends its scan first, rejects at once with
   * OperationCancelled; when destroy() does, with BluetoothManagerDestroyed.
   */
  public findAndConnect(deviceId: string, options?: FindAndConnectOptions): Promise<string> {
    return this._settle<string>(deviceId, (settlement) => {
      const {
        scanTimeout = FIND_AND_CONNECT_SCAN_TIMEOUT_MS,
        serviceUUIDs,
        onDisconnect,
        onFound,
        ...connectOptions
      } = options ?? {};
      if (this.isConnected(deviceId)) {
        this.connect(deviceId, connectOptions, onDisconnect).then(settlement.resolve, settlement.reject);
        return;
      }
      const wanted = canonicalDeviceId(deviceId);
      // The scan callbacks below use `timer`, set right after the scan
      // started: they run later, on a JS task of their own.
      const fail = (error: BleError) => {
        clearTimeout(timer);
        settlement.reject(error);
      };
      const session = this._startScan(
        { serviceUUIDs },
        (device) => {
          if (canonicalDeviceId(device.id) !== wanted) return;
          clearTimeout(timer);
          try {
            this._stopScanSession(session, null);
          } catch (thrown) {
            settlement.reject(thrown);
            return;
          }
          this.connect(deviceId, connectOptions, onDisconnect).then(settlement.resolve, settlement.reject);
          onFound?.(device);
        },
        fail,
        fail
      );
      const timer = setTimeout(() => {
        settlement.reject(
          new BleError(BleErrorCode.DeviceNotFound, `Device ${deviceId} not found within ${scanTimeout} ms of scanning`)
        );
        // Throws only when the native stopScan does; the promise has settled,
        // so that error reaches the global error handler, like one thrown from
        // a scan callback.
        this._stopScanSession(session, null);
      }, scanTimeout);
    });
  }

  /** Disconnects from a device, or cancels a pending connect to it. See disconnect in NativeBleNitro.nitro.ts. */
  public disconnect(deviceId: string): Promise<void> {
    return this._operation(deviceId, (callback) => this._native.disconnect(deviceId, callback));
  }

  public isConnected(deviceId: string): boolean {
    return this._sync(deviceId, () => this._native.isConnected(deviceId));
  }

  /** Requests an ATT MTU and resolves with the ATT MTU in effect. See requestMTU in NativeBleNitro.nitro.ts. */
  public requestMTU(deviceId: string, mtu: number): Promise<number> {
    return this._request<number>(deviceId, (callback) => this._native.requestMTU(deviceId, mtu, callback));
  }

  /**
   * The ATT MTU in effect on the link, or undefined when the device isn't
   * connected. See getMtu in NativeBleNitro.nitro.ts.
   */
  public getMtu(deviceId: string): number | undefined {
    return this._sync(deviceId, () => this._native.getMtu(deviceId));
  }

  /** See requestConnectionPriority in NativeBleNitro.nitro.ts. */
  public requestConnectionPriority(deviceId: string, priority: AndroidConnectionPriority): Promise<void> {
    return this._operation(deviceId, (callback) =>
      this._native.requestConnectionPriority(deviceId, CONNECTION_PRIORITY_TO_NATIVE[priority], callback)
    );
  }

  public readRSSI(deviceId: string): Promise<number> {
    return this._request<number>(deviceId, (callback) => this._native.readRSSI(deviceId, callback));
  }

  /**
   * Discovers the device's services and the characteristics of each; resolves
   * once all of them are known. See discoverServices in NativeBleNitro.nitro.ts.
   */
  public discoverServices(deviceId: string): Promise<void> {
    return this._operation(deviceId, (callback) => this._native.discoverServices(deviceId, callback));
  }

  /** Discovers the services and resolves with their lowercase 128-bit UUIDs. */
  public async getServices(deviceId: string): Promise<string[]> {
    await this.discoverServices(deviceId);
    return this._sync(deviceId, () => this._native.getServices(deviceId).map(reportedGattUUID));
  }

  /**
   * The lowercase 128-bit UUIDs of a discovered service's characteristics.
   * Needs a completed discovery (discoverServices).
   */
  public getCharacteristics(deviceId: string, serviceId: string): string[] {
    return this._sync(deviceId, () => this._characteristicsOf(deviceId, requireGattUUID(serviceId)));
  }

  /**
   * getServices, with the lowercase 128-bit UUIDs of each service's
   * characteristics. The lists are complete: discoverServices resolves only
   * after every service's characteristics were discovered.
   */
  public async getServicesWithCharacteristics(
    deviceId: string
  ): Promise<{ uuid: string; characteristics: string[] }[]> {
    const services = await this.getServices(deviceId);
    return this._sync(deviceId, () =>
      services.map((uuid) => ({ uuid, characteristics: this._characteristicsOf(deviceId, uuid) }))
    );
  }

  /** Runs inside _sync; `service` is a UUID in its 36-character form. */
  private _characteristicsOf(deviceId: string, service: string): string[] {
    return this._native.getCharacteristics(deviceId, service).map(reportedGattUUID);
  }

  /** See getCharacteristicProperties in NativeBleNitro.nitro.ts. Needs a completed discovery (discoverServices). */
  public getCharacteristicProperties(
    deviceId: string,
    serviceId: string,
    characteristicId: string
  ): CharacteristicProperties | undefined {
    return this._sync(deviceId, () =>
      this._native.getCharacteristicProperties(deviceId, requireGattUUID(serviceId), requireGattUUID(characteristicId))
    );
  }

  /** See readCharacteristic in NativeBleNitro.nitro.ts (including the iOS limit on notifying characteristics). */
  public readCharacteristic(deviceId: string, serviceId: string, characteristicId: string): Promise<ArrayBuffer> {
    return this._request<ArrayBuffer>(deviceId, (callback) =>
      this._native.readCharacteristic(
        deviceId,
        requireGattUUID(serviceId),
        requireGattUUID(characteristicId),
        callback
      )
    );
  }

  /**
   * Writes a characteristic and resolves with the bytes written. See
   * writeCharacteristic in NativeBleNitro.nitro.ts for the length limits, the
   * property checks and when a write without response resolves (awaiting
   * each write paces a burst). The bytes are copied during the call; `data`
   * may be reused right after.
   *
   * @param data The bytes: an ArrayBuffer (all of it), any ArrayBufferView
   *   such as a Uint8Array or a Buffer (exactly the bytes it views, not the
   *   rest of its buffer), or a number[] of integers from 0 to 255. Anything
   *   else, or an array entry outside 0–255, rejects with
   *   CharacteristicInvalidDataFormat and writes nothing.
   */
  public writeCharacteristic(
    deviceId: string,
    serviceId: string,
    characteristicId: string,
    data: ArrayBuffer | ArrayBufferView | ByteArray,
    withResponse: boolean = true
  ): Promise<ArrayBuffer> {
    return this._request<ArrayBuffer>(deviceId, (callback) =>
      this._native.writeCharacteristic(
        deviceId,
        requireGattUUID(serviceId),
        requireGattUUID(characteristicId),
        toWriteBuffer(data),
        withResponse,
        callback
      )
    );
  }

  /**
   * Subscribes to a characteristic's notifications (or indications) and
   * resolves once they are on. See subscribeToCharacteristic in
   * NativeBleNitro.nitro.ts: subscriptions add up, so remove() ends only its
   * own and never silences another subscription to the characteristic, also
   * one C++ sharing this manager made. `onValue` gets each value's bytes as an
   * ArrayBuffer of its own.
   *
   * `onValue` may be called before the promise resolves (the device may
   * notify as soon as its CCCD is on). It is never called after the promise
   * rejected, after remove(), after onEnded, or after destroy().
   *
   * remove() stops the values at once and resolves when the native side
   * released the subscription; it rejects with CharacteristicNotifyChangeFailed
   * when turning notifications off failed, the subscription having ended
   * anyway. Once the subscription ended (onEnded called, destroy()), remove()
   * resolves without doing anything. Every remove() call returns the same
   * promise, so a second caller learns the outcome of the first.
   *
   * @param onEnded See SubscriptionEndedCallback.
   */
  public subscribeToCharacteristic(
    deviceId: string,
    serviceId: string,
    characteristicId: string,
    onValue: CharacteristicUpdateCallback,
    onEnded?: SubscriptionEndedCallback
  ): Promise<AsyncSubscription> {
    return this._settle<AsyncSubscription>(deviceId, (settlement) => {
      const service = requireGattUUID(serviceId);
      const characteristic = requireGattUUID(characteristicId);
      const registration = this._registrations.open();
      try {
        // The id is known before any callback runs: native never calls back
        // inline, and a call into JS from native waits for the JS thread.
        const subscriptionId = this._native.subscribeToCharacteristic(
          deviceId,
          service,
          characteristic,
          (data) => {
            if (this._registrations.isActive(registration)) onValue(data);
          },
          (error) => {
            if (error) {
              this._registrations.end(registration);
              settlement.fail(error);
            } else {
              settlement.resolve(this._subscriptionHandle(deviceId, registration, subscriptionId));
            }
          },
          // Always passed, even without onEnded: an ended subscription must
          // stop being active, so its remove() doesn't go to native.
          (error) => {
            if (this._registrations.end(registration)) onEnded?.(bleErrorFromNative(error, settlement.deviceId));
          }
        );
      } catch (thrown) {
        this._registrations.end(registration);
        throw thrown;
      }
    });
  }

  private _subscriptionHandle(deviceId: string, registration: Registration, subscriptionId: number): AsyncSubscription {
    let removal: Promise<void> | undefined;
    return {
      remove: () =>
        (removal ??= this._registrations.end(registration)
          ? this._operation(deviceId, (callback) => this._native.unsubscribeFromCharacteristic(subscriptionId, callback))
          : Promise.resolve()),
    };
  }

  /** See isSubscribedToCharacteristic in NativeBleNitro.nitro.ts. */
  public isSubscribedToCharacteristic(deviceId: string, serviceId: string, characteristicId: string): boolean {
    return this._sync(deviceId, () =>
      this._native.isSubscribedToCharacteristic(deviceId, requireGattUUID(serviceId), requireGattUUID(characteristicId))
    );
  }

  public isBluetoothEnabled(): boolean {
    return this.state() === BLEState.PoweredOn;
  }

  /** See requestBluetoothEnable in NativeBleNitro.nitro.ts. */
  public requestBluetoothEnable(): Promise<void> {
    return this._operation(undefined, (callback) => this._native.requestBluetoothEnable(callback));
  }

  public state(): BLEState {
    return BLE_STATE_FROM_NATIVE[this._sync(undefined, () => this._native.state())];
  }

  /**
   * Calls `callback` on every Bluetooth state change. Any number of
   * subscriptions may exist; remove() removes only its own, and does nothing
   * the second time.
   *
   * @param emitInitial Also call `callback` with the current state, before
   *   this returns. The listener is registered before the state is read, so
   *   no change is lost in between; a change racing the call may be reported
   *   once more (the last state the callback got is always the current one).
   *   When that initial call throws, the subscription is removed and the
   *   exception propagates.
   */
  public subscribeToStateChange(callback: StateChangeCallback, emitInitial = false): Subscription {
    const subscription = this._addListener(
      (registration) =>
        this._native.subscribeToStateChange((nativeState) => {
          if (this._registrations.isActive(registration)) callback(BLE_STATE_FROM_NATIVE[nativeState]);
        }),
      (listenerId) => this._native.unsubscribeFromStateChange(listenerId)
    );
    if (emitInitial) {
      // Read after registering: the registration and state() run in call
      // order on the native manager's executor, so every change after the
      // read reaches the listener. Reading first could miss a change made
      // between the read and the registration, leaving the listener on a
      // stale state.
      try {
        callback(this.state());
      } catch (error) {
        subscription.remove();
        throw error;
      }
    }
    return subscription;
  }

  /**
   * Calls `callback` for every connection event of this manager's links (see
   * ConnectionEventType in NativeBleNitro.nitro.ts). Any number of
   * subscriptions may exist; remove() removes only its own, and does nothing
   * the second time.
   */
  public onConnectionEvent(callback: ConnectionEventCallback): Subscription {
    return this._addListener(
      (registration) =>
        this._native.subscribeToConnectionEvents((event) => {
          if (this._registrations.isActive(registration)) callback(toConnectionEvent(event));
        }),
      (listenerId) => this._native.unsubscribeFromConnectionEvents(listenerId)
    );
  }

  /** Opens the system's Bluetooth settings. */
  public openSettings(): Promise<void> {
    return this._settle<void>(undefined, (settlement) => {
      this._native.openSettings().then(() => settlement.resolve(undefined), settlement.reject);
    });
  }

  /**
   * Stops scanning, closes every link, fails every pending operation with
   * BluetoothManagerDestroyed and releases the OS resources. See the class
   * documentation for what the JS side guarantees from then on. Idempotent.
   */
  public destroy(): void {
    if (this._destroyed) return;
    this._destroyed = true;
    const session = this._scanSession;
    if (session) this._endScanSession(session, destroyedError(undefined));
    this._registrations.endAll();
    this._restoredStateCallback = null;
    this._restoredState = null;
    try {
      this._native.destroy();
    } catch (thrown) {
      throw bleErrorFromThrown(thrown, undefined);
    }
  }

  /**
   * Registers one JS listener natively and returns its Subscription.
   *
   * Every JS listener gets a native registration of its own (the native
   * manager keeps any number of observers), so listeners are independent:
   * the native side calls each in a JS task of its own, so one that throws
   * reaches the global error handler without keeping the event from the
   * others; and an observer that C++ sharing this manager registers or
   * removes can't replace or remove a JS one.
   */
  private _addListener(
    register: (registration: Registration) => number,
    unregister: (listenerId: number) => void
  ): Subscription {
    return this._sync(undefined, () => {
      const registration = this._registrations.open();
      let listenerId: number;
      try {
        listenerId = register(registration);
      } catch (thrown) {
        this._registrations.end(registration);
        throw thrown;
      }
      return {
        remove: () => {
          if (this._registrations.end(registration)) this._sync(undefined, () => unregister(listenerId));
        },
      };
    });
  }

  private _assertAlive(): void {
    if (this._destroyed) throw destroyedError(undefined);
  }

  /**
   * Runs a synchronous call on `deviceId`'s behalf (validation and the native
   * call); anything it throws becomes a BleError carrying the canonical id.
   */
  private _sync<T>(deviceId: string | undefined, call: () => T): T {
    let id: string | undefined;
    try {
      id = deviceId === undefined ? undefined : canonicalDeviceId(deviceId);
      this._assertAlive();
      return call();
    } catch (thrown) {
      throw bleErrorFromThrown(thrown, id);
    }
  }

  /**
   * The promise of one operation on `deviceId`. `start` validates the input
   * and issues the native call; whatever it throws rejects the promise, so a
   * method returning this never throws.
   *
   * Every way of settling goes through the Settlement, which turns errors
   * into BleErrors carrying the canonical id and applies the destroy() gate:
   * the native side fails every completion it fires after destroy() was
   * called (NativeBleNitro.nitro.ts, "After destroy()"), but a success it
   * fired before reaches the JS thread later, so resolve() checks again here.
   */
  private _settle<T>(deviceId: string | undefined, start: (settlement: Settlement<T>) => void): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let id: string | undefined;
      try {
        id = deviceId === undefined ? undefined : canonicalDeviceId(deviceId);
        this._assertAlive();
        const errorDeviceId = id;
        start({
          deviceId: errorDeviceId,
          resolve: (value) => (this._destroyed ? reject(destroyedError(errorDeviceId)) : resolve(value)),
          fail: (error) => reject(bleErrorFromNative(error, errorDeviceId)),
          reject: (reason) => reject(bleErrorFromThrown(reason, errorDeviceId)),
        });
      } catch (thrown) {
        reject(bleErrorFromThrown(thrown, id));
      }
    });
  }

  /** An operation that completes with an error or nothing. */
  private _operation(deviceId: string | undefined, start: (callback: NativeOperationCallback) => void): Promise<void> {
    return this._settle<void>(deviceId, (settlement) =>
      start((error) => (error ? settlement.fail(error) : settlement.resolve(undefined)))
    );
  }

  /** An operation that completes with an error or a result. */
  private _request<T>(
    deviceId: string | undefined,
    start: (callback: (error: NativeBleError | undefined, result: T | undefined) => void) => void
  ): Promise<T> {
    return this._settle<T>(deviceId, (settlement) =>
      start((error, result) => {
        if (error) {
          settlement.fail(error);
        } else if (result === undefined) {
          settlement.reject(new BleError(BleErrorCode.UnknownError, 'The native operation completed without a result'));
        } else {
          settlement.resolve(result);
        }
      })
    );
  }
}
