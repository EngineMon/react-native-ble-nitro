import type { HybridObject, PlatformSpec } from 'react-native-nitro-modules';
import BleNitroNativeFactory from '../specs/NativeBleNitroFactory';
import {
  AndroidScanMode,
  BLEState,
  BleError,
  BleErrorCode,
  BleNitroManager,
  ConnectionEventType,
  type BLEDevice,
  type ConnectionEvent,
  type ConnectOptions,
  type FindAndConnectOptions,
} from '../index';
import {
  AndroidScanMode as NativeAndroidScanMode,
  BLEState as NativeBLEState,
  ConnectionEventType as NativeConnectionEventType,
  type BLEDevice as NativeBLEDevice,
  type BleError as NativeBleError,
  type NativeBleNitro,
} from '../specs/NativeBleNitro.nitro';

jest.mock('../specs/NativeBleNitroFactory', () => ({
  __esModule: true,
  default: { create: jest.fn() },
}));

/** The native manager's methods, as jest mocks. */
type NativeMethods = Omit<NativeBleNitro, keyof HybridObject<PlatformSpec> | 'restoreStateIdentifier'>;
type MockNative = { [K in keyof NativeMethods]: jest.MockedFunction<NativeMethods[K]> };

function createNative(): MockNative {
  const native: MockNative = {
    iosLazyInit: jest.fn(),
    setRestoreStateCallback: jest.fn(),
    startScan: jest.fn(),
    stopScan: jest.fn(),
    isScanning: jest.fn(),
    getConnectedDevices: jest.fn(),
    connect: jest.fn(),
    disconnect: jest.fn(),
    isConnected: jest.fn(),
    getMtu: jest.fn(),
    requestMTU: jest.fn(),
    requestConnectionPriority: jest.fn(),
    readRSSI: jest.fn(),
    discoverServices: jest.fn(),
    getServices: jest.fn(),
    getCharacteristics: jest.fn(),
    getCharacteristicProperties: jest.fn(),
    readCharacteristic: jest.fn(),
    writeCharacteristic: jest.fn(),
    subscribeToCharacteristic: jest.fn(),
    unsubscribeFromCharacteristic: jest.fn(),
    isSubscribedToCharacteristic: jest.fn(),
    requestBluetoothEnable: jest.fn(),
    state: jest.fn(),
    subscribeToStateChange: jest.fn(),
    unsubscribeFromStateChange: jest.fn(),
    subscribeToConnectionEvents: jest.fn(),
    unsubscribeFromConnectionEvents: jest.fn(),
    openSettings: jest.fn(),
    destroy: jest.fn(),
  };
  // Like the native IdSource: positive, never reused.
  let lastId = 0;
  const nextId = () => ++lastId;
  native.subscribeToCharacteristic.mockImplementation(nextId);
  native.subscribeToStateChange.mockImplementation(nextId);
  native.subscribeToConnectionEvents.mockImplementation(nextId);
  native.stopScan.mockReturnValue(true);
  native.isConnected.mockReturnValue(false);
  native.getServices.mockReturnValue([]);
  native.getCharacteristics.mockReturnValue([]);
  native.state.mockReturnValue(NativeBLEState.PoweredOn);
  return native;
}

const createNativeManager = jest.mocked(BleNitroNativeFactory.create);
let native: MockNative;

beforeEach(() => {
  native = createNative();
  createNativeManager.mockReset();
  // The manager only calls the mocked methods, never the HybridObject ones.
  createNativeManager.mockImplementation(() => native as unknown as NativeBleNitro);
});

afterEach(() => {
  jest.useRealTimers();
});

/** The arguments of the last call of a mock, e.g. to complete the native operation. */
function lastCall<T, Y extends unknown[]>(method: jest.MockInstance<T, Y>): Y {
  const call = method.mock.lastCall;
  if (!call) throw new Error('The mock was not called');
  return call;
}

/** The arguments of one native registration call and the id it returned. */
function registration<Y extends unknown[]>(method: jest.MockInstance<number, Y>, index: number): { args: Y; id: number } {
  const args = method.mock.calls[index];
  const result = method.mock.results[index];
  if (!args || result?.type !== 'return') throw new Error(`The mock has no call ${index}`);
  return { args, id: result.value };
}

function bytes(...values: number[]): ArrayBuffer {
  return new Uint8Array(values).buffer;
}

function bytesOf(buffer: ArrayBuffer): number[] {
  return Array.from(new Uint8Array(buffer));
}

const disconnected: NativeBleError = {
  code: BleErrorCode.DeviceDisconnected,
  message: 'Device was disconnected',
  nativeStatus: 8,
};

const scanFailure: NativeBleError = {
  code: BleErrorCode.ScanStartFailed,
  message: 'Scanning too frequently',
  nativeStatus: 6,
};

function nativeDevice(overrides: Partial<NativeBLEDevice> = {}): NativeBLEDevice {
  return {
    id: 'AA:BB:CC:DD:EE:FF',
    name: 'Sensor',
    rssi: -60,
    manufacturerData: { companyIdentifiers: [{ id: '4660', data: bytes(0x34, 0x12, 0x01) }] },
    serviceData: { services: [{ uuid: '180F', data: bytes(0x64) }] },
    serviceUUIDs: ['180D', '0000FEED-0000-1000-8000-00805F9B34FB'],
    isConnectable: true,
    isConnected: false,
    ...overrides,
  };
}

describe('errors', () => {
  test('a failed operation rejects with a BleError carrying the code, the native status and the canonical device id', async () => {
    const ble = new BleNitroManager();
    const read = ble.readCharacteristic('aa:bb:cc:dd:ee:ff', '180f', '2a19');
    lastCall(native.readCharacteristic)[3](disconnected, undefined);

    await expect(read).rejects.toBeInstanceOf(BleError);
    await expect(read).rejects.toMatchObject({
      name: 'BleError',
      errorCode: BleErrorCode.DeviceDisconnected,
      nativeStatus: 8,
      deviceId: 'AA:BB:CC:DD:EE:FF',
    });
  });

  test('an exception from a native call becomes a BleError (UnknownError) keeping the original as cause', async () => {
    const ble = new BleNitroManager();
    const thrown = new Error('JNI exception');
    native.disconnect.mockImplementation(() => {
      throw thrown;
    });
    native.isConnected.mockImplementation(() => {
      throw thrown;
    });

    await expect(ble.disconnect('dev-1')).rejects.toMatchObject({
      errorCode: BleErrorCode.UnknownError,
      message: 'JNI exception',
      deviceId: 'DEV-1',
      cause: thrown,
    });
    expect(() => ble.isConnected('dev-1')).toThrow(BleError);
  });

  test('an operation settles once: a second native completion is ignored', async () => {
    const ble = new BleNitroManager();
    const rssi = ble.readRSSI('dev-1');
    const complete = lastCall(native.readRSSI)[1];
    complete(undefined, -42);
    complete(disconnected, undefined);

    await expect(rssi).resolves.toBe(-42);
  });
});

describe('GATT UUIDs', () => {
  test.each([
    ['180d', '0000180d-0000-1000-8000-00805f9b34fb'],
    ['180D', '0000180d-0000-1000-8000-00805f9b34fb'],
    ['0000180D', '0000180d-0000-1000-8000-00805f9b34fb'],
    ['FEEDBEEF', 'feedbeef-0000-1000-8000-00805f9b34fb'],
    ['A1B2C3D400014E5F8A9B0C1D2E3F4A5B', 'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b'],
    ['A1B2C3D4-0001-4E5F-8A9B-0C1D2E3F4A5B', 'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b'],
  ])('%s normalizes to %s', (input, expected) => {
    expect(BleNitroManager.normalizeGattUUID(input)).toBe(expected);
  });

  test.each([
    '',
    'abc',
    '12345',
    '180g',
    '0x180d',
    ' 180d',
    'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5',
    'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b0',
    'a1b2c3d40001-4e5f-8a9b-0c1d2e3f4a5b',
    '{a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b}',
  ])('%p is rejected with InvalidIdentifiers', (input) => {
    expect(() => BleNitroManager.normalizeGattUUID(input)).toThrow(
      expect.objectContaining({ errorCode: BleErrorCode.InvalidIdentifiers })
    );
  });

  test('methods returning a promise reject a malformed UUID instead of throwing, and call nothing native', async () => {
    const ble = new BleNitroManager();
    const invalid = { errorCode: BleErrorCode.InvalidIdentifiers, deviceId: 'DEV-1' };

    await expect(ble.readCharacteristic('dev-1', '180f', '2a1')).rejects.toMatchObject(invalid);
    await expect(ble.writeCharacteristic('dev-1', 'battery', '2a19', [1])).rejects.toMatchObject(invalid);
    await expect(
      ble.subscribeToCharacteristic('dev-1', undefined as unknown as string, '2a37', jest.fn())
    ).rejects.toMatchObject(invalid);
    await expect(ble.findAndConnect('dev-1', { serviceUUIDs: ['180d', 'nope'] })).rejects.toMatchObject(invalid);

    expect(native.readCharacteristic).not.toHaveBeenCalled();
    expect(native.writeCharacteristic).not.toHaveBeenCalled();
    expect(native.subscribeToCharacteristic).not.toHaveBeenCalled();
    expect(native.startScan).not.toHaveBeenCalled();
    expect(() => ble.getCharacteristics('dev-1', '18 0d')).toThrow(expect.objectContaining(invalid));
  });
});

describe('connection', () => {
  test('connect resolves with the canonical id and reports disconnects with a BleError', async () => {
    const ble = new BleNitroManager();
    const onDisconnect = jest.fn<void, [string, boolean, BleError | undefined]>();

    const connect = ble.connect('aa:bb:cc:dd:ee:ff', { timeoutMs: 10_000 }, onDisconnect);
    const [, , complete, disconnectCallback] = lastCall(native.connect);
    complete(undefined);
    await expect(connect).resolves.toBe('AA:BB:CC:DD:EE:FF');

    disconnectCallback?.('AA:BB:CC:DD:EE:FF', true, disconnected);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    const [id, interrupted, error] = lastCall(onDisconnect);
    expect([id, interrupted]).toEqual(['AA:BB:CC:DD:EE:FF', true]);
    expect(error).toBeInstanceOf(BleError);
    expect(error).toMatchObject({
      errorCode: BleErrorCode.DeviceDisconnected,
      nativeStatus: 8,
      deviceId: 'AA:BB:CC:DD:EE:FF',
    });
  });

  test('connect and findAndConnect take a null options object like an absent one', async () => {
    const ble = new BleNitroManager();

    const connect = ble.connect('dev-1', null as unknown as ConnectOptions);
    lastCall(native.connect)[2](undefined);
    await expect(connect).resolves.toBe('DEV-1');

    const find = ble.findAndConnect('dev-2', null as unknown as FindAndConnectOptions);
    lastCall(native.startScan)[1](nativeDevice({ id: 'DEV-2' }), undefined);
    lastCall(native.connect)[2](undefined);
    await expect(find).resolves.toBe('DEV-2');
  });

  test('disconnect goes to native while not connected, cancelling a pending connect', async () => {
    const ble = new BleNitroManager();

    const connect = ble.connect('dev-1');
    const disconnect = ble.disconnect('dev-1');
    expect(native.disconnect).toHaveBeenCalledWith('dev-1', expect.any(Function));

    lastCall(native.connect)[2]({ code: BleErrorCode.OperationCancelled, message: 'Connection cancelled' });
    lastCall(native.disconnect)[1](undefined);
    await expect(connect).rejects.toMatchObject({ errorCode: BleErrorCode.OperationCancelled });
    await expect(disconnect).resolves.toBeUndefined();
  });

  test('getServicesWithCharacteristics resolves after discovery with lowercase 128-bit UUIDs', async () => {
    const ble = new BleNitroManager();
    native.getServices.mockReturnValue(['180F', 'A1B2C3D4-0001-4E5F-8A9B-0C1D2E3F4A5B']);
    native.getCharacteristics.mockImplementation((_deviceId, service) =>
      service === '0000180f-0000-1000-8000-00805f9b34fb' ? ['2A19'] : ['A1B2C3D4-0002-4E5F-8A9B-0C1D2E3F4A5B']
    );

    const services = ble.getServicesWithCharacteristics('dev-1');
    expect(native.getServices).not.toHaveBeenCalled();
    lastCall(native.discoverServices)[1](undefined);

    await expect(services).resolves.toEqual([
      { uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: ['00002a19-0000-1000-8000-00805f9b34fb'] },
      { uuid: 'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b', characteristics: ['a1b2c3d4-0002-4e5f-8a9b-0c1d2e3f4a5b'] },
    ]);
  });
});

describe('connection events', () => {
  test('each listener gets the events with a string type and a BleError; remove() unregisters only its own, once', () => {
    const ble = new BleNitroManager();
    const first = jest.fn<void, [ConnectionEvent]>();
    const second = jest.fn<void, [ConnectionEvent]>();
    const firstSubscription = ble.onConnectionEvent(first);
    ble.onConnectionEvent(second);
    const {
      args: [emitFirst],
      id: firstId,
    } = registration(native.subscribeToConnectionEvents, 0);
    const {
      args: [emitSecond],
    } = registration(native.subscribeToConnectionEvents, 1);

    emitFirst({
      deviceId: 'AA:BB:CC:DD:EE:FF',
      type: NativeConnectionEventType.Disconnected,
      interrupted: true,
      error: disconnected,
    });
    expect(first).toHaveBeenCalledTimes(1);
    const [event] = lastCall(first);
    expect(event).toMatchObject({ deviceId: 'AA:BB:CC:DD:EE:FF', type: ConnectionEventType.Disconnected, interrupted: true });
    expect(event.error).toBeInstanceOf(BleError);
    expect(event.error).toMatchObject({
      errorCode: BleErrorCode.DeviceDisconnected,
      nativeStatus: 8,
      deviceId: 'AA:BB:CC:DD:EE:FF',
    });

    emitFirst({ deviceId: 'AA:BB:CC:DD:EE:FF', type: NativeConnectionEventType.ServicesChanged, interrupted: false });
    expect(lastCall(first)[0]).toEqual({
      deviceId: 'AA:BB:CC:DD:EE:FF',
      type: ConnectionEventType.ServicesChanged,
      interrupted: false,
      error: undefined,
    });

    firstSubscription.remove();
    firstSubscription.remove();
    expect(native.unsubscribeFromConnectionEvents).toHaveBeenCalledTimes(1);
    expect(native.unsubscribeFromConnectionEvents).toHaveBeenCalledWith(firstId);

    // An event already on its way to the JS thread when remove() ran.
    const connected = { deviceId: 'AA:BB:CC:DD:EE:FF', type: NativeConnectionEventType.Connected, interrupted: false };
    emitFirst(connected);
    emitSecond(connected);
    expect(first).toHaveBeenCalledTimes(2);
    expect(lastCall(second)[0]).toMatchObject({ type: ConnectionEventType.Connected });
  });
});

describe('scanning', () => {
  test('passes the filter with normalized UUIDs and no RSSI floor unless one is given', () => {
    const ble = new BleNitroManager();
    ble.startScan({ serviceUUIDs: ['180D'] }, jest.fn());
    expect(lastCall(native.startScan)[0]).toEqual({
      serviceUUIDs: ['0000180d-0000-1000-8000-00805f9b34fb'],
      rssiThreshold: undefined,
      allowDuplicates: false,
      androidScanMode: NativeAndroidScanMode.Balanced,
    });

    ble.startScan({ rssiThreshold: -90, allowDuplicates: true, androidScanMode: AndroidScanMode.LowLatency }, jest.fn());
    expect(lastCall(native.startScan)[0]).toEqual({
      serviceUUIDs: [],
      rssiThreshold: -90,
      allowDuplicates: true,
      androidScanMode: NativeAndroidScanMode.LowLatency,
    });
  });

  test('reports devices with normalized UUIDs and advertisement bytes as number[]', () => {
    const ble = new BleNitroManager();
    const onDevice = jest.fn<void, [BLEDevice]>();
    ble.startScan({}, onDevice);
    lastCall(native.startScan)[1](nativeDevice(), undefined);

    const expected: BLEDevice = {
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'Sensor',
      rssi: -60,
      manufacturerData: { companyIdentifiers: [{ id: '4660', data: [0x34, 0x12, 0x01] }] },
      serviceData: { services: [{ uuid: '0000180f-0000-1000-8000-00805f9b34fb', data: [0x64] }] },
      serviceUUIDs: ['0000180d-0000-1000-8000-00805f9b34fb', '0000feed-0000-1000-8000-00805f9b34fb'],
      isConnectable: true,
      isConnected: false,
    };
    expect(onDevice).toHaveBeenCalledWith(expected);
  });

  test('a new scan replaces the running one, and a stopped scan reports nothing more', () => {
    const ble = new BleNitroManager();
    const first = jest.fn();
    const second = jest.fn();

    ble.startScan({}, first);
    const firstCallback = lastCall(native.startScan)[1];
    ble.startScan({}, second);
    const secondCallback = lastCall(native.startScan)[1];

    firstCallback(nativeDevice(), undefined);
    secondCallback(nativeDevice(), undefined);
    ble.stopScan();
    secondCallback(nativeDevice(), undefined);

    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);
  });

  test('an invalid filter throws InvalidIdentifiers and leaves the running scan untouched', () => {
    const ble = new BleNitroManager();
    const onDevice = jest.fn();
    ble.startScan({}, onDevice);
    const callback = lastCall(native.startScan)[1];

    expect(() => ble.startScan({ serviceUUIDs: ['heart rate'] }, jest.fn())).toThrow(
      expect.objectContaining({ errorCode: BleErrorCode.InvalidIdentifiers })
    );
    expect(native.stopScan).not.toHaveBeenCalled();
    expect(native.startScan).toHaveBeenCalledTimes(1);
    callback(nativeDevice(), undefined);
    expect(onDevice).toHaveBeenCalledTimes(1);
  });

  test('a scan failure ends the scan and goes to onError, or is thrown without onError', () => {
    const ble = new BleNitroManager();
    const onDevice = jest.fn();
    const onError = jest.fn<void, [BleError]>();

    ble.startScan({}, onDevice, onError);
    const callback = lastCall(native.startScan)[1];
    callback(undefined, scanFailure);
    callback(nativeDevice(), undefined);

    expect(onDevice).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledTimes(1);
    const [scanError] = lastCall(onError);
    expect(scanError).toBeInstanceOf(BleError);
    expect(scanError).toMatchObject({ errorCode: BleErrorCode.ScanStartFailed, nativeStatus: 6 });

    ble.startScan({}, onDevice);
    expect(() => lastCall(native.startScan)[1](undefined, scanFailure)).toThrow(BleError);
  });
});

describe('findAndConnect', () => {
  test('scans with the service filter, matches the id in any letter case, then stops the scan and connects', async () => {
    const ble = new BleNitroManager();
    const onFound = jest.fn<void, [BLEDevice]>();
    const result = ble.findAndConnect('aa:bb:cc:dd:ee:02', {
      serviceUUIDs: ['180D'],
      onFound,
      autoConnectAndroid: true,
    });

    const [filter, scanCallback] = lastCall(native.startScan);
    expect(filter.serviceUUIDs).toEqual(['0000180d-0000-1000-8000-00805f9b34fb']);
    scanCallback(nativeDevice({ id: 'AA:BB:CC:DD:EE:01' }), undefined);
    expect(native.connect).not.toHaveBeenCalled();
    scanCallback(nativeDevice({ id: 'AA:BB:CC:DD:EE:02' }), undefined);

    expect(native.stopScan).toHaveBeenCalledTimes(1);
    expect(onFound).toHaveBeenCalledWith(expect.objectContaining({ id: 'AA:BB:CC:DD:EE:02' }));
    const [, options, complete] = lastCall(native.connect);
    expect(options).toMatchObject({ autoConnect: true });
    complete(undefined);
    await expect(result).resolves.toBe('AA:BB:CC:DD:EE:02');
  });

  test('rejects with DeviceNotFound when the scan does not find the device in time', async () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const result = ble.findAndConnect('dev-2', { scanTimeout: 1000 });

    jest.advanceTimersByTime(1000);
    await expect(result).rejects.toMatchObject({ errorCode: BleErrorCode.DeviceNotFound, deviceId: 'DEV-2' });
    expect(native.stopScan).toHaveBeenCalledTimes(1);
    expect(native.connect).not.toHaveBeenCalled();
  });

  test('rejects with the scan error when its scan fails, without a later DeviceNotFound or stop', async () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const result = ble.findAndConnect('dev-2', { scanTimeout: 1000 });

    lastCall(native.startScan)[1](undefined, scanFailure);
    jest.advanceTimersByTime(1000);
    await expect(result).rejects.toMatchObject({ errorCode: BleErrorCode.ScanStartFailed, nativeStatus: 6, deviceId: 'DEV-2' });
    expect(native.stopScan).not.toHaveBeenCalled();
  });

  test('once the device was found, its scan timeout leaves a scan started later alone', async () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const result = ble.findAndConnect('dev-2', { scanTimeout: 1000 });
    lastCall(native.startScan)[1](nativeDevice({ id: 'DEV-2' }), undefined);
    lastCall(native.connect)[2](undefined);
    await expect(result).resolves.toBe('DEV-2');

    const onDevice = jest.fn();
    ble.startScan({}, onDevice);
    jest.advanceTimersByTime(1000);
    lastCall(native.startScan)[1](nativeDevice(), undefined);
    expect(onDevice).toHaveBeenCalledTimes(1);
    expect(native.stopScan).toHaveBeenCalledTimes(1);
  });

  test('connects to an already connected device without scanning', async () => {
    const ble = new BleNitroManager();
    native.isConnected.mockReturnValue(true);
    const onDisconnect = jest.fn();
    const result = ble.findAndConnect('dev-2', { onDisconnect });

    expect(native.startScan).not.toHaveBeenCalled();
    const [, , complete, disconnectCallback] = lastCall(native.connect);
    complete(undefined);
    await expect(result).resolves.toBe('DEV-2');
    disconnectCallback?.('DEV-2', false, undefined);
    expect(onDisconnect).toHaveBeenCalledWith('DEV-2', false, undefined);
  });

  test('rejects at once with OperationCancelled when a newer scan or stopScan() ends its scan', async () => {
    // Fake timers that never advance: a rejection can't come from the timeout.
    jest.useFakeTimers();
    const ble = new BleNitroManager();

    const replaced = ble.findAndConnect('dev-1');
    const onDevice = jest.fn();
    ble.startScan({}, onDevice);
    await expect(replaced).rejects.toMatchObject({ errorCode: BleErrorCode.OperationCancelled, deviceId: 'DEV-1' });
    lastCall(native.startScan)[1](nativeDevice({ id: 'dev-1' }), undefined);
    expect(onDevice).toHaveBeenCalledTimes(1);

    const stopped = ble.findAndConnect('dev-1');
    ble.stopScan();
    await expect(stopped).rejects.toMatchObject({ errorCode: BleErrorCode.OperationCancelled });
    expect(native.connect).not.toHaveBeenCalled();
  });

  test('rejects at once with BluetoothManagerDestroyed when destroy() ends its scan', async () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const result = ble.findAndConnect('dev-1');

    ble.destroy();
    await expect(result).rejects.toMatchObject({ errorCode: BleErrorCode.BluetoothManagerDestroyed, deviceId: 'DEV-1' });
  });
});

describe('Bluetooth state', () => {
  test('every listener registers natively; remove() unregisters only its own, once', () => {
    const ble = new BleNitroManager();
    const first = jest.fn();
    const second = jest.fn();

    const firstSubscription = ble.subscribeToStateChange(first);
    const secondSubscription = ble.subscribeToStateChange(second);
    const {
      args: [emitFirst],
      id: firstId,
    } = registration(native.subscribeToStateChange, 0);
    const {
      args: [emitSecond],
      id: secondId,
    } = registration(native.subscribeToStateChange, 1);
    emitFirst(NativeBLEState.PoweredOff);
    emitSecond(NativeBLEState.PoweredOff);
    expect(first).toHaveBeenLastCalledWith(BLEState.PoweredOff);
    expect(second).toHaveBeenLastCalledWith(BLEState.PoweredOff);

    firstSubscription.remove();
    firstSubscription.remove();
    expect(native.unsubscribeFromStateChange).toHaveBeenCalledTimes(1);
    expect(native.unsubscribeFromStateChange).toHaveBeenCalledWith(firstId);

    // A change already on its way to the JS thread when remove() ran.
    emitFirst(NativeBLEState.Unauthorized);
    emitSecond(NativeBLEState.Unauthorized);
    expect(first).toHaveBeenCalledTimes(1);
    expect(second).toHaveBeenLastCalledWith(BLEState.Unauthorized);

    secondSubscription.remove();
    expect(native.unsubscribeFromStateChange).toHaveBeenLastCalledWith(secondId);
  });

  test('emitInitial registers before reading the state, and reports it before returning', () => {
    const ble = new BleNitroManager();
    const steps: string[] = [];
    native.subscribeToStateChange.mockImplementation(() => {
      steps.push('register');
      return 1;
    });
    native.state.mockImplementation(() => {
      steps.push('read');
      return NativeBLEState.PoweredOff;
    });
    const callback = jest.fn();

    ble.subscribeToStateChange(callback, true);
    expect(steps).toEqual(['register', 'read']);
    expect(callback).toHaveBeenCalledWith(BLEState.PoweredOff);

    lastCall(native.subscribeToStateChange)[0](NativeBLEState.PoweredOn);
    expect(callback).toHaveBeenLastCalledWith(BLEState.PoweredOn);
  });

  test('when the emitInitial call throws, the exception propagates and the listener is removed', () => {
    const ble = new BleNitroManager();
    const bug = new Error('listener bug');
    const callback = jest.fn(() => {
      throw bug;
    });

    expect(() => ble.subscribeToStateChange(callback, true)).toThrow(bug);
    const {
      args: [emit],
      id,
    } = registration(native.subscribeToStateChange, 0);
    expect(native.unsubscribeFromStateChange).toHaveBeenCalledWith(id);
    emit(NativeBLEState.PoweredOff);
    expect(callback).toHaveBeenCalledTimes(1);
  });
});

describe('writes', () => {
  test('resolve with the bytes written once native completes; withResponse defaults to true', async () => {
    const ble = new BleNitroManager();

    const write = ble.writeCharacteristic('dev-1', '180F', '2A19', bytes(1, 2, 3), false);
    const [, service, characteristic, data, withResponse, complete] = lastCall(native.writeCharacteristic);
    expect([service, characteristic, withResponse]).toEqual([
      '0000180f-0000-1000-8000-00805f9b34fb',
      '00002a19-0000-1000-8000-00805f9b34fb',
      false,
    ]);
    expect(bytesOf(data)).toEqual([1, 2, 3]);
    let settled = false;
    write.then(() => (settled = true));
    await Promise.resolve();
    expect(settled).toBe(false);
    const response = bytes(1, 2, 3);
    complete(undefined, response);
    await expect(write).resolves.toBe(response);

    ble.writeCharacteristic('dev-1', '180f', '2a19', [0x00, 0xde, 0xff]);
    const [, , , converted, defaultWithResponse] = lastCall(native.writeCharacteristic);
    expect(bytesOf(converted)).toEqual([0x00, 0xde, 0xff]);
    expect(defaultWithResponse).toBe(true);
  });

  test('a view is written as exactly the bytes it views, not the rest of its buffer', () => {
    const ble = new BleNitroManager();
    const backing = bytes(0, 1, 2, 3, 4, 5);

    ble.writeCharacteristic('dev-1', '180f', '2a19', new Uint8Array(backing, 2, 3));
    expect(bytesOf(lastCall(native.writeCharacteristic)[3])).toEqual([2, 3, 4]);
    ble.writeCharacteristic('dev-1', '180f', '2a19', new Uint8Array(backing).subarray(4));
    expect(bytesOf(lastCall(native.writeCharacteristic)[3])).toEqual([4, 5]);
    ble.writeCharacteristic('dev-1', '180f', '2a19', new DataView(backing, 1, 2));
    expect(bytesOf(lastCall(native.writeCharacteristic)[3])).toEqual([1, 2]);
    // A small Node-style Buffer lives in a shared pool buffer.
    ble.writeCharacteristic('dev-1', '180f', '2a19', Buffer.from([0xaa, 0xbb]));
    expect(bytesOf(lastCall(native.writeCharacteristic)[3])).toEqual([0xaa, 0xbb]);
    ble.writeCharacteristic('dev-1', '180f', '2a19', new Uint8Array([7, 8]));
    expect(bytesOf(lastCall(native.writeCharacteristic)[3])).toEqual([7, 8]);
  });

  test.each([[[256]], [[-1]], [[1.5]], [[NaN]], [[1, '2']], [[null]]])(
    'data %p rejects with CharacteristicInvalidDataFormat and writes nothing',
    async (data) => {
      const ble = new BleNitroManager();
      await expect(
        ble.writeCharacteristic('dev-1', '180f', '2a19', data as number[])
      ).rejects.toMatchObject({ errorCode: BleErrorCode.CharacteristicInvalidDataFormat, deviceId: 'DEV-1' });
      expect(native.writeCharacteristic).not.toHaveBeenCalled();
    }
  );

  test('data that is no bytes at all rejects with CharacteristicInvalidDataFormat', async () => {
    const ble = new BleNitroManager();
    await expect(
      ble.writeCharacteristic('dev-1', '180f', '2a19', 'ab' as unknown as number[])
    ).rejects.toMatchObject({ errorCode: BleErrorCode.CharacteristicInvalidDataFormat });
    expect(native.writeCharacteristic).not.toHaveBeenCalled();
  });
});

describe('characteristic subscriptions', () => {
  test('subscribe resolves once the CCCD write completed; values arriving before are delivered too', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn<void, [ArrayBuffer]>();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180D', '2A37', onValue);
    const [, service, characteristic, notify, complete] = lastCall(native.subscribeToCharacteristic);
    expect([service, characteristic]).toEqual([
      '0000180d-0000-1000-8000-00805f9b34fb',
      '00002a37-0000-1000-8000-00805f9b34fb',
    ]);

    const early = bytes(0x06, 0x40);
    notify(early);
    expect(lastCall(onValue)[0]).toBe(early);
    let subscribed = false;
    subscribe.then(() => (subscribed = true));
    await Promise.resolve();
    expect(subscribed).toBe(false);
    complete(undefined);
    await subscribe;

    const value = bytes(0x06, 0x48);
    notify(value);
    expect(onValue).toHaveBeenCalledTimes(2);
    expect(lastCall(onValue)[0]).toBe(value);
  });

  test('remove() ends only its own subscription: another one of the same characteristic keeps receiving', async () => {
    const ble = new BleNitroManager();
    const older = jest.fn();
    const newer = jest.fn();

    const olderSubscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', older);
    const {
      args: [, , , olderNotify, olderComplete],
      id: olderId,
    } = registration(native.subscribeToCharacteristic, 0);
    olderComplete(undefined);
    const olderSubscription = await olderSubscribe;

    // The older one is removed while the newer subscribe is still pending.
    const newerSubscribe = ble.subscribeToCharacteristic('dev-1', '0000180d-0000-1000-8000-00805f9b34fb', '2A37', newer);
    const {
      args: [, , , newerNotify, newerComplete],
    } = registration(native.subscribeToCharacteristic, 1);
    const remove = olderSubscription.remove();
    expect(native.unsubscribeFromCharacteristic).toHaveBeenCalledTimes(1);
    const [removedId, unsubscribed] = lastCall(native.unsubscribeFromCharacteristic);
    expect(removedId).toBe(olderId);
    unsubscribed(undefined);
    await remove;
    newerComplete(undefined);
    await newerSubscribe;

    olderNotify(bytes(1));
    newerNotify(bytes(2));
    expect(older).not.toHaveBeenCalled();
    expect(newer).toHaveBeenCalledTimes(1);
  });

  test('remove() stops the values at once; every call shares the outcome of the one unsubscribe', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue);
    const [, , , notify, complete] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    const subscription = await subscribe;

    const remove = subscription.remove();
    const secondRemove = subscription.remove();
    notify(bytes(1));
    expect(onValue).not.toHaveBeenCalled();
    lastCall(native.unsubscribeFromCharacteristic)[1]({
      code: BleErrorCode.CharacteristicNotifyChangeFailed,
      message: 'Descriptor write failed',
      nativeStatus: 133,
    });
    const failed = { errorCode: BleErrorCode.CharacteristicNotifyChangeFailed, nativeStatus: 133, deviceId: 'DEV-1' };
    await expect(remove).rejects.toMatchObject(failed);
    await expect(secondRemove).rejects.toMatchObject(failed);
    await expect(subscription.remove()).rejects.toMatchObject(failed);
    expect(native.unsubscribeFromCharacteristic).toHaveBeenCalledTimes(1);
  });

  test('an ended subscription calls onEnded once, gets no more values, and its remove() does nothing', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn();
    const onEnded = jest.fn<void, [BleError]>();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue, onEnded);
    const [, , , notify, complete, ended] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    const subscription = await subscribe;

    ended?.(disconnected);
    expect(onEnded).toHaveBeenCalledTimes(1);
    const [error] = lastCall(onEnded);
    expect(error).toBeInstanceOf(BleError);
    expect(error).toMatchObject({ errorCode: BleErrorCode.DeviceDisconnected, nativeStatus: 8, deviceId: 'DEV-1' });
    notify(bytes(1));
    expect(onValue).not.toHaveBeenCalled();
    await expect(subscription.remove()).resolves.toBeUndefined();

    // Without onEnded, an ended subscription's remove() does nothing either.
    const quietSubscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', jest.fn());
    const [, , , , quietComplete, quietEnded] = lastCall(native.subscribeToCharacteristic);
    quietComplete(undefined);
    const quiet = await quietSubscribe;
    quietEnded?.(disconnected);
    await expect(quiet.remove()).resolves.toBeUndefined();

    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });

  test('onEnded is not called once remove() has started', async () => {
    const ble = new BleNitroManager();
    const onEnded = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', jest.fn(), onEnded);
    const [, , , , complete, ended] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    const subscription = await subscribe;

    const remove = subscription.remove();
    // The link went down while the unsubscribe was queued.
    ended?.(disconnected);
    lastCall(native.unsubscribeFromCharacteristic)[1](undefined);
    await remove;
    expect(onEnded).not.toHaveBeenCalled();
  });

  test('a failed subscribe rejects and delivers nothing afterwards', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue);
    const [, , , notify, complete] = lastCall(native.subscribeToCharacteristic);

    complete({ code: BleErrorCode.CharacteristicNotifyChangeFailed, message: 'CCCD write failed', nativeStatus: 133 });
    await expect(subscribe).rejects.toMatchObject({
      errorCode: BleErrorCode.CharacteristicNotifyChangeFailed,
      nativeStatus: 133,
      deviceId: 'DEV-1',
    });
    notify(bytes(1));
    expect(onValue).not.toHaveBeenCalled();
  });

  test('a subscribe whose native call throws rejects, and nothing is released natively later', async () => {
    const ble = new BleNitroManager();
    const thrown = new Error('JNI exception');
    native.subscribeToCharacteristic.mockImplementationOnce(() => {
      throw thrown;
    });

    await expect(ble.subscribeToCharacteristic('dev-1', '180d', '2a37', jest.fn())).rejects.toMatchObject({
      errorCode: BleErrorCode.UnknownError,
      deviceId: 'DEV-1',
      cause: thrown,
    });
    ble.destroy();
    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });
});

describe('state restoration', () => {
  test('peripherals restored before a callback is set are kept and passed to the first callback once', () => {
    const ble = new BleNitroManager({ restoreIdentifier: 'restore-key' });
    const [identifier, restore] = lastCall(createNativeManager);
    expect(identifier).toBe('restore-key');
    if (!restore) throw new Error('The manager passed no restore callback');

    restore([nativeDevice({ id: 'DEV-1', isConnected: true })]);
    const first = jest.fn<void, [BLEDevice[]]>();
    const second = jest.fn<void, [BLEDevice[]]>();
    ble.onRestoredState(first);
    ble.onRestoredState(second);

    expect(first).toHaveBeenCalledTimes(1);
    expect(lastCall(first)[0]).toEqual([expect.objectContaining({ id: 'DEV-1', isConnected: true })]);
    expect(second).not.toHaveBeenCalled();
  });
});

describe('destroy', () => {
  test('no listener is called afterwards, not even for reports already on their way', async () => {
    const ble = new BleNitroManager();
    const onState = jest.fn();
    ble.subscribeToStateChange(onState);
    const emitState = lastCall(native.subscribeToStateChange)[0];
    const onEvent = jest.fn();
    ble.onConnectionEvent(onEvent);
    const emitEvent = lastCall(native.subscribeToConnectionEvents)[0];
    const onDisconnect = jest.fn();
    const connect = ble.connect('dev-1', {}, onDisconnect);
    const [, , connected, disconnectCallback] = lastCall(native.connect);
    connected(undefined);
    await connect;
    const onValue = jest.fn();
    const onEnded = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue, onEnded);
    const [, , , notify, complete, ended] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    await subscribe;
    const onPendingValue = jest.fn();
    ble.subscribeToCharacteristic('dev-1', '180d', '2a38', onPendingValue).catch(() => undefined);
    const [, , , pendingNotify] = lastCall(native.subscribeToCharacteristic);

    ble.destroy();
    ble.destroy();
    expect(native.destroy).toHaveBeenCalledTimes(1);

    emitState(NativeBLEState.PoweredOff);
    emitEvent({ deviceId: 'DEV-1', type: NativeConnectionEventType.Disconnected, interrupted: false });
    disconnectCallback?.('DEV-1', false, undefined);
    notify(bytes(1));
    ended?.({ code: BleErrorCode.BluetoothManagerDestroyed, message: 'Manager destroyed' });
    pendingNotify(bytes(2));
    expect(onState).not.toHaveBeenCalled();
    expect(onEvent).not.toHaveBeenCalled();
    expect(onDisconnect).not.toHaveBeenCalled();
    expect(onValue).not.toHaveBeenCalled();
    expect(onEnded).not.toHaveBeenCalled();
    expect(onPendingValue).not.toHaveBeenCalled();
  });

  test('a success the native side sent before destroy() rejects with BluetoothManagerDestroyed', async () => {
    const ble = new BleNitroManager();
    const read = ble.readCharacteristic('dev-1', '180f', '2a19');
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', jest.fn());
    const connect = ble.connect('dev-2');

    ble.destroy();
    lastCall(native.readCharacteristic)[3](undefined, bytes(0x64));
    lastCall(native.subscribeToCharacteristic)[4](undefined);
    lastCall(native.connect)[2](undefined);

    const destroyed = { errorCode: BleErrorCode.BluetoothManagerDestroyed };
    await expect(read).rejects.toMatchObject({ ...destroyed, deviceId: 'DEV-1' });
    await expect(subscribe).rejects.toMatchObject(destroyed);
    await expect(connect).rejects.toMatchObject({ ...destroyed, deviceId: 'DEV-2' });
    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });

  test('later calls fail with BluetoothManagerDestroyed; releasing calls do nothing', async () => {
    const ble = new BleNitroManager();
    const stateSubscription = ble.subscribeToStateChange(jest.fn());
    const eventSubscription = ble.onConnectionEvent(jest.fn());
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', jest.fn());
    lastCall(native.subscribeToCharacteristic)[4](undefined);
    const valueSubscription = await subscribe;

    ble.destroy();

    await expect(ble.connect('dev-1')).rejects.toMatchObject({
      errorCode: BleErrorCode.BluetoothManagerDestroyed,
      deviceId: 'DEV-1',
    });
    expect(native.connect).not.toHaveBeenCalled();
    const destroyed = expect.objectContaining({ errorCode: BleErrorCode.BluetoothManagerDestroyed });
    expect(() => ble.state()).toThrow(destroyed);
    expect(() => ble.startScan({}, jest.fn())).toThrow(destroyed);
    expect(() => ble.subscribeToStateChange(jest.fn())).toThrow(destroyed);
    expect(() => ble.onConnectionEvent(jest.fn())).toThrow(destroyed);

    ble.stopScan();
    stateSubscription.remove();
    eventSubscription.remove();
    await expect(valueSubscription.remove()).resolves.toBeUndefined();
    expect(native.stopScan).not.toHaveBeenCalled();
    expect(native.unsubscribeFromStateChange).not.toHaveBeenCalled();
    expect(native.unsubscribeFromConnectionEvents).not.toHaveBeenCalled();
    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });
});
