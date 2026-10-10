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
  /** The canonical device id (see NativeBleNitro, "Device ids"). */
  id: string;
  name: string;
  rssi: number;
  manufacturerData: ManufacturerData;
  serviceData: ServiceData;
  serviceUUIDs: string[];
  isConnectable: boolean;
  /** Whether this manager's link to the device is up. */
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
   * when it isn't up after this many milliseconds. Absent or Infinity: the OS
   * decides (Android about 30 s, iOS never). NaN, 0 or negative: connect
   * fails with OperationStartFailed.
   * iOS, an attempt this manager took over (see connect): the timeout fails
   * only the call and never cancels the OS's attempt.
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

/**
 * The properties a characteristic declares (Bluetooth Core Vol 3 Part G
 * §3.3.1.1). Operations check them before sending anything: read needs read,
 * a write with response needs write, a write without response needs
 * writeWithoutResponse (neither write type stands in for the other), a
 * subscription needs notify or indicate.
 */
export interface CharacteristicProperties {
  read: boolean;
  write: boolean;
  writeWithoutResponse: boolean;
  notify: boolean;
  indicate: boolean;
}

export enum ConnectionEventType {
  /**
   * A link became this manager's. Fires once per link: in the same executor
   * task as, and right before, the success callback of the connect() that
   * brought the link up or adopted it (iOS: a restored link). iOS also fires
   * it when an attempt the OS kept pending (see connect) connects while no
   * connect() waits: the link is kept and the next connect() succeeds at once.
   */
  Connected = 0,
  /**
   * A link that fired Connected went down. Fires right after the link's
   * disconnect callback, with the same interrupted and error. Not for the
   * links destroy() closes (no listener fires once destroy() was called).
   */
  Disconnected = 1,
  /**
   * The device changed its GATT database (Service Changed indication,
   * Bluetooth Core Vol 3 Part G §7.1). The subscriptions on the changed
   * services ended (endedCallback with ServicesNotDiscovered; Android ends
   * every subscription of the link, since it doesn't tell which services
   * changed) and operations on them fail until discoverServices ran again.
   * Android 12 (API 31) and later, and iOS; never on older Android.
   */
  ServicesChanged = 2,
}

export interface ConnectionEvent {
  /** The canonical device id. */
  deviceId: string;
  type: ConnectionEventType;
  /** Disconnected: the disconnect callback's. False otherwise. */
  interrupted: boolean;
  /** Disconnected: the disconnect callback's. Absent otherwise. */
  error?: BleError;
}

// Every asynchronous operation completes exactly once: with no error, or with
// one. Results are present exactly when there is no error.
export type OperationCallback = (error: BleError | undefined) => void;
export type ScanCallback = (device: BLEDevice | undefined, error: BleError | undefined) => void;
/**
 * A link went down after its connect succeeded. interrupted = false and no
 * error after disconnect(); otherwise interrupted = true with the reason:
 * DeviceDisconnected when the link was lost (nativeStatus: the OS's status),
 * OperationTimedOut when an operation timed out and took it down. Never for
 * the links destroy() closes (no listener fires once destroy() was called).
 */
export type DisconnectionEventCallback = (deviceId: string, interrupted: boolean, error: BleError | undefined) => void;
export type NotificationCallback = (data: BLEValue) => void;
export type StateCallback = (state: BLEState) => void;
export type ReadCharacteristicCallback = (error: BleError | undefined, data: BLEValue | undefined) => void;
export type WriteCharacteristicCallback = (error: BleError | undefined, responseData: BLEValue | undefined) => void;
export type ReadRSSICallback = (error: BleError | undefined, rssi: number | undefined) => void;
export type MtuCallback = (error: BleError | undefined, mtu: number | undefined) => void;
export type RestoreCallback = (restoredPeripherals: BLEDevice[]) => void;
export type ConnectionEventCallback = (event: ConnectionEvent) => void;
/**
 * Fires once when a subscription ends without its owner unsubscribing: link
 * lost or disconnect() by anyone (DeviceDisconnected), operation timeout
 * (OperationTimedOut), services changed (ServicesNotDiscovered), and on
 * Android a failed service discovery (ServicesNotDiscovered, nativeStatus:
 * the GATT status): the OS drops its service list when a discovery starts,
 * so a discovery it accepted but answered with an error leaves no database
 * for the subscriptions (the call itself fails with ServicesDiscoveryFailed);
 * a discovery the OS refuses to start changes nothing. Never after destroy()
 * was called: the subscriptions it ends end silently.
 */
export type SubscriptionEndedCallback = (error: BleError) => void;

/**
 * One BLE central manager. This documentation is the behavior contract of
 * both implementations (Android BleNitroBleManager.kt, iOS
 * BleNitroBleManager.swift).
 *
 * Threading:
 * 1. Each manager has one serial executor that owns all of its BLE state
 *    (Android: a HandlerThread that also receives every
 *    BluetoothGattCallback; iOS: the CBCentralManager's serial
 *    DispatchQueue). Calls run on it in the order they were made (per
 *    calling thread).
 * 2. Every callback runs on that executor, in the order the OS delivered the
 *    events, across all devices and characteristics. Never inline on the
 *    calling thread (also not when a call fails at once), and never from a
 *    synchronous method. JS callbacks then hop to the JS thread (Nitro); C++
 *    callbacks run on the executor itself and must not block it. After
 *    destroy(), completions still run asynchronously (Android: on one
 *    process-wide fallback thread; iOS: on the manager's queue).
 * 3. Every completion callback fires exactly once; a listener fires until it
 *    is removed. C++ callbacks must not throw: iOS calls them through
 *    noexcept bridges, so an exception terminates the process (Android logs
 *    and drops it).
 * 4. Synchronous methods (the getters, stopScan, unsubscribeFromStateChange,
 *    unsubscribeFromConnectionEvents) wait until the executor ran them; called
 *    from a callback they run inline. destroy() called off the executor waits
 *    for the executor too (see destroy()); from a callback it doesn't wait. A
 *    C++ caller must not call one of these while holding a lock that its BLE
 *    callbacks take: the executor may be running such a callback, blocked on
 *    that lock, and both wait forever. JS callbacks never hold the executor
 *    (Nitro queues them for the JS thread), so a call from JS can't deadlock
 *    this way. The subscribe methods return their id without waiting.
 *
 * Device ids are canonical: Android the uppercase MAC address, iOS the
 * uppercase peripheral UUID. Methods accept any letter case; callbacks,
 * events and BLEDevice.id carry the canonical form. Subscription and
 * listener ids are positive integers, never reused within the process.
 *
 * UUIDs: service and characteristic UUIDs are accepted in four forms, any
 * letter case: 4 hex digits (a 16-bit UUID, e.g. "180D"), 8 hex digits (a
 * 32-bit UUID), 32 hex digits, and the canonical 36-character form with
 * dashes after the 8th, 12th, 16th and 20th digit. The 16- and 32-bit forms
 * stand for the Bluetooth Base UUID with those bits set (Bluetooth Core
 * Specification Vol 3 Part B §2.5.1). Anything else is an invalid
 * identifier. Callbacks and results carry the lowercase 36-character form.
 *
 * Operations on one device run one at a time, in call order (Android's GATT
 * allows one outstanding operation per connection). Characteristic
 * operations look the characteristic up when they start, so one queued
 * behind discoverServices sees its result. They fail, in this order of
 * checks, with:
 * - InvalidIdentifiers (5): a device id or UUID that doesn't parse (see
 *   "UUIDs").
 * - DeviceNotConnected (205): this manager has no link up to the device.
 * - ServicesNotDiscovered (303): no discovery completed on this link, or the
 *   device's services changed since (ConnectionEventType.ServicesChanged).
 * - ServiceNotFound (302); CharacteristicsNotDiscovered (405): the service's
 *   characteristics aren't discovered; CharacteristicNotFound (404).
 * - The operation's own code when the characteristic's declared properties
 *   (CharacteristicProperties) don't allow it: read 402, write 401,
 *   subscribe 403, without nativeStatus.
 *
 * Timeouts: an operation the OS doesn't answer within 30 s (read, write,
 * subscribe, unsubscribe, discovery, RSSI, MTU) fails with OperationTimedOut
 * and takes the link down. After an ATT transaction timed out, no further
 * ATT request may be sent on that bearer (Bluetooth Core Vol 3 Part F
 * §3.3.3), and Android keeps its GATT client busy until the late answer, so
 * every later operation would fail anyway. Queued operations then fail with
 * DeviceDisconnected, subscriptions end with OperationTimedOut, and the
 * disconnect callback gets interrupted = true with OperationTimedOut.
 * Android 14+ MTU requests never time out (see requestMTU).
 *
 * When a link goes down, every pending operation of it fails with
 * DeviceDisconnected (BluetoothManagerDestroyed on destroy) and every
 * subscription on it ends (silently on destroy: no endedCallback, see
 * below).
 *
 * After destroy() (from the moment it is called, on any thread):
 * - Every completion (operations, pending connects and disconnects,
 *   subscribe completions, unsubscribes, requestBluetoothEnable) that fires
 *   from then on fails exactly once with BluetoothManagerDestroyed, whatever
 *   produced it: a call made afterwards, an operation the teardown ends, or
 *   an OS answer that was already on its way. A startScan whose start hadn't
 *   reached the OS reports BluetoothManagerDestroyed through its callback; a
 *   scan already running ends silently.
 * - No listener fires again (updates, endedCallback, state, connection
 *   events, disconnect callbacks, scan results), also not for the links and
 *   subscriptions destroy() itself ends.
 * - Once destroy() returned, no listener is running either (it waits for
 *   one that already started, see destroy()), so a C++ caller may release
 *   its listener state.
 * - The subscribe methods still return an id; synchronous methods return
 *   their empty value (false, [], undefined, Unknown).
 */
export interface NativeBleNitro extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  // iOS only. Android ignores these: it has no state restoration.
  /**
   * iOS: the CoreBluetooth state restoration identifier
   * (CBCentralManagerOptionRestoreIdentifierKey), from the factory's
   * restoreStateIdentifier. It takes effect when the CBCentralManager is
   * created: right after the manager is created, or with lazy init
   * (Info.plist BLENitroLazyInit) at iosLazyInit() or the first call that
   * needs the central; setting it after that changes nothing. Android: kept
   * as set and otherwise unused.
   */
  restoreStateIdentifier?: string;
  setRestoreStateCallback(callback: RestoreCallback): void;
  iosLazyInit(): void;

  /**
   * One scan per manager: starting another replaces the running one, whose
   * callback then gets nothing more. A start that fails before reaching the
   * OS (invalid filter, Android's scan-start throttle) leaves the running
   * scan alone and reports the error to the new callback only. Failures to
   * start or run a scan reach the callback (device undefined), never thrown.
   */
  startScan(filter: ScanFilter, callback: ScanCallback): void;
  /** Returns whether a scan was running. Its callback gets nothing more. */
  stopScan(): boolean;
  isScanning(): boolean;

  /**
   * Connected devices. isConnected tells whether this manager's link is up;
   * the others are connected to the system and need connect() first.
   * - This manager's links that are up whose discovered services include one
   *   of `services` (every link that is up when it is empty). A name in
   *   `services` that doesn't parse matches nothing.
   * - Android adds, only when `services` is empty, the other devices the OS
   *   has a GATT connection to (Android can't tell their services). Never
   *   throws: without the BLUETOOTH_CONNECT permission these are left out.
   * - iOS adds, only when `services` isn't empty, the peripherals connected
   *   to the system that offer one of them (retrieveConnectedPeripherals).
   */
  getConnectedDevices(services: string[]): BLEDevice[];

  /**
   * Connects and completes once the link is up.
   * - This manager's link to the device is already up (iOS: or iOS restored
   *   it): succeeds at once. A present disconnectCallback replaces the
   *   installed one, an absent one keeps it.
   * - A connect() to the device is still pending: fails with
   *   DeviceAlreadyConnected; the pending one goes on.
   * - iOS: an attempt the OS keeps pending that this manager didn't start
   *   (e.g. restored) is taken over, not replaced; options.timeoutMs then
   *   fails only this call and never cancels the OS's attempt (it isn't this
   *   call's to cancel).
   * - The link is being taken down (operation timeout): connects anew once it
   *   is down.
   */
  connect(deviceId: string, options: ConnectOptions, callback: OperationCallback, disconnectCallback?: DisconnectionEventCallback): void;
  /**
   * Cancels a pending connect (which then fails with OperationCancelled),
   * fails the queued operations at once with DeviceDisconnected, and
   * completes once the link is down.
   */
  disconnect(deviceId: string, callback: OperationCallback): void;
  /** Whether this manager's link to the device is up. */
  isConnected(deviceId: string): boolean;
  /**
   * The ATT MTU in effect on this manager's link; undefined when it isn't
   * up. Android: 23 when the link comes up, then the result of every MTU
   * exchange (requestMTU's, one the device started, or the one Android 14+
   * starts by itself). iOS: maximumWriteValueLength(.withoutResponse) + 3.
   * The longest write without response is min(getMtu − 3, 512).
   */
  getMtu(deviceId: string): number | undefined;
  /**
   * `mtu`: an integer in 23...517 (else DeviceMTUChangeFailed). Completes
   * with the ATT MTU in effect: on Android the value negotiated
   * (onMtuChanged); Android 14+ makes only the first exchange of a
   * connection (requesting 517 itself), so a later request completes with
   * the current MTU (at once, or after 3 s without an answer). iOS: the one
   * CoreBluetooth negotiated by itself (getMtu).
   */
  requestMTU(deviceId: string, mtu: number, callback: MtuCallback): void;
  /** Android only; elsewhere completes without error while the link is up (DeviceNotConnected otherwise). */
  requestConnectionPriority(deviceId: string, androidConnectionPriority: AndroidConnectionPriority, callback: OperationCallback): void;
  readRSSI(deviceId: string, callback: ReadRSSICallback): void;

  /**
   * Discovers the services and their characteristics (both platforms): the
   * database characteristic operations look up. Needed once per link, and
   * again after ServicesChanged. Fails with ServicesNotDiscovered when the
   * services changed while it ran. Android: when the OS answers it with an
   * error it fails with ServicesDiscoveryFailed and ends every subscription
   * of the link (see SubscriptionEndedCallback).
   */
  discoverServices(deviceId: string, callback: OperationCallback): void;
  /** The discovered services; empty when the link isn't up or nothing is discovered. */
  getServices(deviceId: string): string[];
  /** The discovered characteristics of a service; empty when unknown. */
  getCharacteristics(deviceId: string, serviceId: string): string[];
  /** A discovered characteristic's declared properties; undefined when the lookup fails. */
  getCharacteristicProperties(deviceId: string, serviceId: string, characteristicId: string): CharacteristicProperties | undefined;

  /**
   * Needs the read property (CharacteristicReadFailed otherwise).
   * iOS limit: CoreBluetooth reports a read response and a notification
   * through the same callback (peripheral(_:didUpdateValueFor:error:)), so a
   * read of a characteristic that is notifying completes with whichever of
   * the two arrives first. Every value still reaches the subscribers.
   */
  readCharacteristic(deviceId: string, serviceId: string, characteristicId: string, callback: ReadCharacteristicCallback): void;
  /**
   * Writes with response (ATT Write Request) or without (Write Command).
   * - Needs the matching declared property, write or writeWithoutResponse
   *   (CharacteristicWriteFailed otherwise).
   * - At most 512 bytes, the longest attribute value (Bluetooth Core Vol 3
   *   Part F §3.2.9); without response at most min(getMtu − 3, 512), what one
   *   Write Command carries (Core Vol 3 Part G §4.9.1). Longer data fails
   *   with CharacteristicWriteFailed and nothing is sent (Android would send
   *   it truncated, or throw from Android 15 when over 512 bytes).
   * - A write without response completes when the OS accepted it for sending
   *   (Android onCharacteristicWrite, iOS canSendWriteWithoutResponse), so
   *   awaiting each write paces a burst.
   */
  writeCharacteristic(deviceId: string, serviceId: string, characteristicId: string, data: BLEValue, withResponse: boolean, callback: WriteCharacteristicCallback): void;
  /**
   * Adds a subscriber to the characteristic's notifications (or indications
   * when it only indicates) and returns its subscription id.
   * - Subscribers add up, each with its own callbacks. The CCCD (Client
   *   Characteristic Configuration descriptor) is written on with the first
   *   subscriber on the link and off after the last one, only when its state
   *   must change.
   * - updateCallback gets every value from the moment the subscription is
   *   made, also before completionCallback (a device may notify as soon as
   *   its CCCD is on). Each value is a buffer of its own, valid after the
   *   callback returns.
   * - completionCallback: no error once notifications are on. On error the
   *   subscription is over (no more values, endedCallback never fires):
   *   the lookup and property errors above, CharacteristicNotifyChangeFailed
   *   with nativeStatus when the CCCD write failed, OperationCancelled when
   *   it was unsubscribed first, or what would have ended it (see
   *   SubscriptionEndedCallback).
   * - endedCallback: see SubscriptionEndedCallback. Never fires after
   *   unsubscribeFromCharacteristic.
   */
  subscribeToCharacteristic(
    deviceId: string,
    serviceId: string,
    characteristicId: string,
    updateCallback: NotificationCallback,
    completionCallback: OperationCallback,
    endedCallback?: SubscriptionEndedCallback,
  ): number;
  /**
   * Ends the subscription. From the moment this runs on the executor its
   * callbacks get nothing more (a pending completionCallback fails with
   * OperationCancelled), so none fires after `callback`. Writes the CCCD off
   * when it was the characteristic's last subscriber. A failed write is
   * reported as CharacteristicNotifyChangeFailed (nativeStatus: the GATT/ATT
   * status), but the subscription is ended either way. Completes without
   * error when the link goes down first, and for an unknown or already ended
   * id (e.g. its link went down).
   */
  unsubscribeFromCharacteristic(subscriptionId: number, callback: OperationCallback): void;
  /** Whether an active subscription of this manager (completed, not ended) exists on the characteristic. */
  isSubscribedToCharacteristic(deviceId: string, serviceId: string, characteristicId: string): boolean;

  /**
   * Android: asks the user to turn Bluetooth on and completes without error
   * once they did (at once when it is on), with OperationCancelled when they
   * declined, BluetoothStateChangeFailed when there is no activity to ask
   * from. iOS doesn't let apps turn Bluetooth on: BluetoothStateChangeFailed.
   */
  requestBluetoothEnable(callback: OperationCallback): void;
  state(): BLEState;
  /**
   * Adds a listener for every later adapter state change (not the current
   * state: read state()) and returns its id.
   */
  subscribeToStateChange(stateCallback: StateCallback): number;
  /** Synchronous: once it returns, the listener is never called again. An unknown id does nothing. */
  unsubscribeFromStateChange(listenerId: number): void;
  /** Adds a listener for the connection events of every device of this manager and returns its id. */
  subscribeToConnectionEvents(callback: ConnectionEventCallback): number;
  /** Synchronous: once it returns, the listener is never called again. An unknown id does nothing. */
  unsubscribeFromConnectionEvents(listenerId: number): void;
  openSettings(): Promise<void>;

  /**
   * Stops scanning, closes every link, fails every pending operation with
   * BluetoothManagerDestroyed and releases the OS resources. Silently: no
   * listener fires from the moment it is called (no disconnect callbacks,
   * endedCallbacks or Disconnected events for what it closes). Called off
   * the executor, it waits until a listener callback already running on the
   * executor returned (it runs no callback itself and doesn't wait for the
   * teardown; threading rule 4 applies); called from a callback, it doesn't
   * wait. The teardown then completes asynchronously. The manager is unusable
   * afterwards (see "After destroy()" above). Idempotent.
   */
  destroy(): void;
}
