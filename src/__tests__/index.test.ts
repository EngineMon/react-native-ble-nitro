import type { HybridObject, PlatformSpec } from 'react-native-nitro-modules';
import BleNitroNativeFactory from '../specs/NativeBleNitroFactory';
import {
  AndroidConnectionPriority,
  AndroidScanMode,
  BLEState,
  BleError,
  BleErrorCode,
  BleNitroManager,
  type BLEDevice,
} from '../index';
import {
  AndroidScanMode as NativeAndroidScanMode,
  BLEState as NativeBLEState,
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
    requestMTU: jest.fn(),
    requestConnectionPriority: jest.fn(),
    readRSSI: jest.fn(),
    discoverServices: jest.fn(),
    discoverServicesWithCharacteristics: jest.fn(),
    getServices: jest.fn(),
    getCharacteristics: jest.fn(),
    readCharacteristic: jest.fn(),
    writeCharacteristic: jest.fn(),
    subscribeToCharacteristic: jest.fn(),
    unsubscribeFromCharacteristic: jest.fn(),
    isSubscribedToCharacteristic: jest.fn(),
    requestBluetoothEnable: jest.fn(),
    state: jest.fn(),
    subscribeToStateChange: jest.fn(),
    unsubscribeFromStateChange: jest.fn(),
    openSettings: jest.fn(),
    destroy: jest.fn(),
  };
  native.stopScan.mockReturnValue(true);
  native.isConnected.mockReturnValue(false);
  native.getServices.mockReturnValue([]);
  native.getCharacteristics.mockReturnValue([]);
  native.state.mockReturnValue(NativeBLEState.PoweredOn);
  native.subscribeToStateChange.mockReturnValue({ success: true });
  native.unsubscribeFromStateChange.mockReturnValue({ success: true });
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

function bytes(...values: number[]): ArrayBuffer {
  return new Uint8Array(values).buffer;
}

const disconnected: NativeBleError = {
  code: BleErrorCode.DeviceDisconnected,
  message: 'Device was disconnected',
  nativeStatus: 8,
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
  test('a failed operation rejects with a BleError carrying the code, the native status and the device', async () => {
    const ble = new BleNitroManager();
    const read = ble.readCharacteristic('dev-1', '180f', '2a19');
    lastCall(native.readCharacteristic)[3](disconnected, undefined);

    await expect(read).rejects.toBeInstanceOf(BleError);
    await expect(read).rejects.toMatchObject({
      name: 'BleError',
      errorCode: BleErrorCode.DeviceDisconnected,
      message: 'Device was disconnected',
      nativeStatus: 8,
      deviceId: 'dev-1',
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
      deviceId: 'dev-1',
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

describe('connection', () => {
  test('connect goes to native even when the device is connected, and reports disconnects with a BleError', async () => {
    const ble = new BleNitroManager();
    native.isConnected.mockReturnValue(true);
    const onDisconnect = jest.fn<void, [string, boolean, BleError | undefined]>();

    const connect = ble.connect('dev-1', { refreshGattAndroid: true, timeoutMs: 10_000 }, onDisconnect);
    const [deviceId, options, complete, disconnectCallback] = lastCall(native.connect);
    expect(deviceId).toBe('dev-1');
    expect(options).toEqual({ autoConnect: undefined, refreshGatt: true, timeoutMs: 10_000 });
    complete(undefined);
    await expect(connect).resolves.toBe('dev-1');

    expect(disconnectCallback).toBeDefined();
    disconnectCallback?.('dev-1', true, disconnected);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    const [id, interrupted, error] = lastCall(onDisconnect);
    expect([id, interrupted]).toEqual(['dev-1', true]);
    expect(error).toBeInstanceOf(BleError);
    expect(error).toMatchObject({ errorCode: BleErrorCode.DeviceDisconnected, nativeStatus: 8, deviceId: 'dev-1' });
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

  test('requestConnectionPriority maps the priority and resolves on completion', async () => {
    const ble = new BleNitroManager();
    const request = ble.requestConnectionPriority('dev-1', AndroidConnectionPriority.High);
    const [, priority, complete] = lastCall(native.requestConnectionPriority);
    expect(priority).toBe(1);
    complete(undefined);
    await expect(request).resolves.toBeUndefined();
  });

  test('getServicesWithCharacteristics resolves after discovery with lowercase 128-bit UUIDs', async () => {
    const ble = new BleNitroManager();
    native.getServices.mockReturnValue(['180F', 'A1B2C3D4-0001-4E5F-8A9B-0C1D2E3F4A5B']);
    native.getCharacteristics.mockImplementation((_deviceId, service) =>
      service === '0000180f-0000-1000-8000-00805f9b34fb' ? ['2A19'] : ['A1B2C3D4-0002-4E5F-8A9B-0C1D2E3F4A5B']
    );

    const services = ble.getServicesWithCharacteristics('dev-1');
    expect(native.getServices).not.toHaveBeenCalled();
    lastCall(native.discoverServicesWithCharacteristics)[1](undefined);

    await expect(services).resolves.toEqual([
      { uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: ['00002a19-0000-1000-8000-00805f9b34fb'] },
      { uuid: 'a1b2c3d4-0001-4e5f-8a9b-0c1d2e3f4a5b', characteristics: ['a1b2c3d4-0002-4e5f-8a9b-0c1d2e3f4a5b'] },
    ]);
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
    expect(native.stopScan).toHaveBeenCalledTimes(1);

    firstCallback(nativeDevice(), undefined);
    secondCallback(nativeDevice(), undefined);
    ble.stopScan();
    secondCallback(nativeDevice(), undefined);

    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);
  });

  test('a scan failure ends the scan and goes to onError, or is thrown without onError', () => {
    const ble = new BleNitroManager();
    const onDevice = jest.fn();
    const onError = jest.fn<void, [BleError]>();
    const failure: NativeBleError = { code: BleErrorCode.ScanStartFailed, message: 'Scanning too frequently', nativeStatus: 6 };

    ble.startScan({}, onDevice, onError);
    const callback = lastCall(native.startScan)[1];
    callback(undefined, failure);
    callback(nativeDevice(), undefined);

    expect(onDevice).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledTimes(1);
    const [scanError] = lastCall(onError);
    expect(scanError).toBeInstanceOf(BleError);
    expect(scanError).toMatchObject({ errorCode: BleErrorCode.ScanStartFailed, nativeStatus: 6 });

    ble.startScan({}, onDevice);
    expect(() => lastCall(native.startScan)[1](undefined, failure)).toThrow(BleError);
  });
});

describe('findAndConnect', () => {
  test('connects once the scan finds the device, and stops the scan', async () => {
    const ble = new BleNitroManager();
    const onFound = jest.fn<void, [BLEDevice]>();
    const result = ble.findAndConnect('dev-2', { onFound, autoConnectAndroid: true });

    const scanCallback = lastCall(native.startScan)[1];
    scanCallback(nativeDevice({ id: 'dev-1' }), undefined);
    expect(native.connect).not.toHaveBeenCalled();
    scanCallback(nativeDevice({ id: 'dev-2' }), undefined);

    expect(native.stopScan).toHaveBeenCalledTimes(1);
    expect(onFound).toHaveBeenCalledWith(expect.objectContaining({ id: 'dev-2' }));
    const [deviceId, options, complete] = lastCall(native.connect);
    expect(deviceId).toBe('dev-2');
    expect(options).toMatchObject({ autoConnect: true });
    complete(undefined);
    await expect(result).resolves.toBe('dev-2');
  });

  test('rejects with DeviceNotFound when the scan does not find the device in time', async () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const result = ble.findAndConnect('dev-2', { scanTimeout: 1000 });

    jest.advanceTimersByTime(1000);
    await expect(result).rejects.toMatchObject({ errorCode: BleErrorCode.DeviceNotFound, deviceId: 'dev-2' });
    expect(native.stopScan).toHaveBeenCalledTimes(1);
    expect(native.connect).not.toHaveBeenCalled();
  });

  test('connects to an already connected device without scanning', async () => {
    const ble = new BleNitroManager();
    native.isConnected.mockReturnValue(true);
    const onDisconnect = jest.fn();
    const result = ble.findAndConnect('dev-2', { onDisconnect });

    expect(native.startScan).not.toHaveBeenCalled();
    const [, , complete, disconnectCallback] = lastCall(native.connect);
    complete(undefined);
    await expect(result).resolves.toBe('dev-2');
    disconnectCallback?.('dev-2', false, undefined);
    expect(onDisconnect).toHaveBeenCalledWith('dev-2', false, undefined);
  });
});

describe('Bluetooth state', () => {
  test('one native subscription serves every subscriber; remove() removes only its own', () => {
    const ble = new BleNitroManager();
    const first = jest.fn();
    const second = jest.fn();

    const firstSubscription = ble.subscribeToStateChange(first, true);
    const secondSubscription = ble.subscribeToStateChange(second);
    expect(native.subscribeToStateChange).toHaveBeenCalledTimes(1);
    expect(first).toHaveBeenCalledWith(BLEState.PoweredOn);
    expect(second).not.toHaveBeenCalled();

    const emit = lastCall(native.subscribeToStateChange)[0];
    emit(NativeBLEState.PoweredOff);
    expect(first).toHaveBeenLastCalledWith(BLEState.PoweredOff);
    expect(second).toHaveBeenLastCalledWith(BLEState.PoweredOff);

    firstSubscription.remove();
    expect(native.unsubscribeFromStateChange).not.toHaveBeenCalled();
    emit(NativeBLEState.Unauthorized);
    expect(first).toHaveBeenCalledTimes(2);
    expect(second).toHaveBeenLastCalledWith(BLEState.Unauthorized);

    secondSubscription.remove();
    secondSubscription.remove();
    expect(native.unsubscribeFromStateChange).toHaveBeenCalledTimes(1);

    ble.subscribeToStateChange(jest.fn());
    expect(native.subscribeToStateChange).toHaveBeenCalledTimes(2);
  });

  test('a throwing subscriber does not keep the state from the others; its error is rethrown', () => {
    jest.useFakeTimers();
    const ble = new BleNitroManager();
    const after = jest.fn();
    ble.subscribeToStateChange(() => {
      throw new Error('subscriber bug');
    });
    ble.subscribeToStateChange(after);

    lastCall(native.subscribeToStateChange)[0](NativeBLEState.PoweredOff);
    expect(after).toHaveBeenCalledWith(BLEState.PoweredOff);
    expect(() => jest.runOnlyPendingTimers()).toThrow('subscriber bug');
  });
});

describe('characteristics', () => {
  test('writes pass an ArrayBuffer through as is, convert a number[] once, and resolve when native completes', async () => {
    const ble = new BleNitroManager();
    const payload = bytes(1, 2, 3);

    const write = ble.writeCharacteristic('dev-1', '180F', '2A19', payload, false);
    const [deviceId, service, characteristic, data, withResponse, complete] = lastCall(native.writeCharacteristic);
    expect([deviceId, service, characteristic, withResponse]).toEqual([
      'dev-1',
      '0000180f-0000-1000-8000-00805f9b34fb',
      '00002a19-0000-1000-8000-00805f9b34fb',
      false,
    ]);
    expect(data).toBe(payload);
    let settled = false;
    write.then(() => (settled = true));
    await Promise.resolve();
    expect(settled).toBe(false);
    const response = bytes(1, 2, 3);
    complete(undefined, response);
    await expect(write).resolves.toBe(response);

    ble.writeCharacteristic('dev-1', '180f', '2a19', [0xde, 0xad]);
    const [, , , converted, defaultWithResponse] = lastCall(native.writeCharacteristic);
    expect(converted).toBeInstanceOf(ArrayBuffer);
    expect(Array.from(new Uint8Array(converted))).toEqual([0xde, 0xad]);
    expect(defaultWithResponse).toBe(true);
  });

  test('subscribe resolves once the CCCD write completed and delivers each value as its native ArrayBuffer', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn<void, [ArrayBuffer]>();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180D', '2A37', onValue);
    const [, service, characteristic, notify, complete] = lastCall(native.subscribeToCharacteristic);
    expect([service, characteristic]).toEqual([
      '0000180d-0000-1000-8000-00805f9b34fb',
      '00002a37-0000-1000-8000-00805f9b34fb',
    ]);

    let subscribed = false;
    subscribe.then(() => (subscribed = true));
    await Promise.resolve();
    expect(subscribed).toBe(false);
    complete(undefined);
    await subscribe;

    const value = bytes(0x06, 0x48);
    notify(value);
    expect(onValue).toHaveBeenCalledTimes(1);
    expect(lastCall(onValue)[0]).toBe(value);
  });

  test('remove() unsubscribes and drops later values; a failed unsubscribe rejects', async () => {
    const ble = new BleNitroManager();
    const onValue = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue);
    const [, , , notify, complete] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    const subscription = await subscribe;

    const remove = subscription.remove();
    notify(bytes(1));
    expect(onValue).not.toHaveBeenCalled();
    lastCall(native.unsubscribeFromCharacteristic)[3]({
      code: BleErrorCode.CharacteristicNotifyChangeFailed,
      message: 'Descriptor write failed',
      nativeStatus: 133,
    });
    await expect(remove).rejects.toMatchObject({
      errorCode: BleErrorCode.CharacteristicNotifyChangeFailed,
      nativeStatus: 133,
      deviceId: 'dev-1',
    });

    await expect(subscription.remove()).resolves.toBeUndefined();
    expect(native.unsubscribeFromCharacteristic).toHaveBeenCalledTimes(1);
  });

  test('a newer subscription to the same characteristic supersedes the older one', async () => {
    const ble = new BleNitroManager();
    const older = jest.fn();
    const newer = jest.fn();

    const olderSubscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', older);
    const [, , , olderNotify, olderComplete] = lastCall(native.subscribeToCharacteristic);
    olderComplete(undefined);
    const olderSubscription = await olderSubscribe;

    const newerSubscribe = ble.subscribeToCharacteristic('dev-1', '0000180d-0000-1000-8000-00805f9b34fb', '2A37', newer);
    const [, , , newerNotify, newerComplete] = lastCall(native.subscribeToCharacteristic);
    newerComplete(undefined);
    await newerSubscribe;

    olderNotify(bytes(1));
    newerNotify(bytes(2));
    await olderSubscription.remove();

    expect(older).not.toHaveBeenCalled();
    expect(newer).toHaveBeenCalledTimes(1);
    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });
});

describe('state restoration', () => {
  test('peripherals restored before a callback is set are kept and passed to the first callback once', () => {
    const ble = new BleNitroManager({ restoreIdentifier: 'restore-key' });
    const [identifier, restore] = lastCall(createNativeManager);
    expect(identifier).toBe('restore-key');
    if (!restore) throw new Error('The manager passed no restore callback');

    restore([nativeDevice({ id: 'dev-1', isConnected: true })]);
    const first = jest.fn<void, [BLEDevice[]]>();
    const second = jest.fn<void, [BLEDevice[]]>();
    ble.onRestoredState(first);
    ble.onRestoredState(second);

    expect(first).toHaveBeenCalledTimes(1);
    expect(lastCall(first)[0]).toEqual([expect.objectContaining({ id: 'dev-1', isConnected: true })]);
    expect(second).not.toHaveBeenCalled();

    restore([nativeDevice({ id: 'dev-2' })]);
    expect(second).toHaveBeenCalledWith([expect.objectContaining({ id: 'dev-2' })]);
  });
});

describe('destroy', () => {
  test('releases native once, ends subscriptions, and makes later calls fail with BluetoothManagerDestroyed', async () => {
    const ble = new BleNitroManager();
    const onState = jest.fn();
    const stateSubscription = ble.subscribeToStateChange(onState);
    const emitState = lastCall(native.subscribeToStateChange)[0];
    const onValue = jest.fn();
    const subscribe = ble.subscribeToCharacteristic('dev-1', '180d', '2a37', onValue);
    const [, , , notify, complete] = lastCall(native.subscribeToCharacteristic);
    complete(undefined);
    const valueSubscription = await subscribe;
    const pendingRead = ble.readCharacteristic('dev-1', '180f', '2a19');

    ble.destroy();
    ble.destroy();
    expect(native.destroy).toHaveBeenCalledTimes(1);

    lastCall(native.readCharacteristic)[3](
      { code: BleErrorCode.BluetoothManagerDestroyed, message: 'Manager destroyed' },
      undefined
    );
    await expect(pendingRead).rejects.toMatchObject({ errorCode: BleErrorCode.BluetoothManagerDestroyed });

    emitState(NativeBLEState.PoweredOff);
    notify(bytes(1));
    expect(onState).not.toHaveBeenCalled();
    expect(onValue).not.toHaveBeenCalled();

    await expect(ble.connect('dev-1')).rejects.toMatchObject({
      errorCode: BleErrorCode.BluetoothManagerDestroyed,
      deviceId: 'dev-1',
    });
    expect(native.connect).not.toHaveBeenCalled();
    expect(() => ble.state()).toThrow(expect.objectContaining({ errorCode: BleErrorCode.BluetoothManagerDestroyed }));
    expect(() => ble.startScan({}, jest.fn())).toThrow(BleError);

    ble.stopScan();
    stateSubscription.remove();
    await expect(valueSubscription.remove()).resolves.toBeUndefined();
    expect(native.stopScan).not.toHaveBeenCalled();
    expect(native.unsubscribeFromStateChange).not.toHaveBeenCalled();
    expect(native.unsubscribeFromCharacteristic).not.toHaveBeenCalled();
  });
});
