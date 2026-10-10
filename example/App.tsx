import { StatusBar } from 'expo-status-bar';
import { AppState, PermissionsAndroid, Platform, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { createBle } from './src/bluetooth';
import { useLayoutEffect, useRef, useState } from 'react';
import { AndroidConnectionPriority, BleError, type BLEDevice, type AsyncSubscription, type Subscription } from 'react-native-ble-nitro';
import { SafeAreaView } from 'react-native-safe-area-context';

const HEART_RATE_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb'.toLowerCase();
const HEART_RATE_MEASUREMENT_UUID = '00002A37-0000-1000-8000-00805f9b34fb'.toLowerCase();
const BODY_SENSOR_LOCATION_UUID = '00002A38-0000-1000-8000-00805f9b34fb'.toLowerCase();

const BATTERY_SERVICE_UUID = '0000180f-0000-1000-8000-00805f9b34fb'.toLowerCase();
const BATTERY_CHARACTERISTIC_LEVEL_UUID = '00002a19-0000-1000-8000-00805f9b34fb'.toLowerCase();

const CUSTOM_SERVICE_UUID = 'AAE28F00-71B5-42A1-8C3C-F9CF6AC969D0'.toLowerCase();
const RX_CHAR_UUID = 'AAE28F01-71B5-42A1-8C3C-F9CF6AC969D0'.toLowerCase();
const TX_CHAR_UUID = 'AAE28F02-71B5-42A1-8C3C-F9CF6AC969D0'.toLowerCase();

const PROFILE_SERVICE_UUID = '0000180A-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_MANUFACTURER_UUID = '00002A29-0000-1000-8000-00805f9b34fb'.toLowerCase();
// const PROFILE_SERIAL_UUID = '00002A25-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_FIRMWARE_UUID = '00002A26-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_HARDWARE_UUID = '00002A27-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_SOFTWARE_UUID = '00002A28-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_MODEL_UUID = '00002A24-0000-1000-8000-00805f9b34fb'.toLowerCase();
const PROFILE_SYSTEMID_UUID = '00002A23-0000-1000-8000-00805f9b34fb'.toLowerCase();

// The remove() of the current subscriptions, null when there is none. Kept
// outside React state so that callbacks created earlier (the disconnect
// callback, onEnded) always see the current subscription, not the one of the
// render that created them.
let unsubscribeRx: AsyncSubscription['remove'] | null = null;
let unsubscribeHr: AsyncSubscription['remove'] | null = null;

export default function App() {
  const [isEnabled, setIsEnabled] = useState(false);
  const [isScanning, setIsScanning] = useState(false);
  const [scanServiceUUIDs, setScanServiceUUIDs] = useState<string>(`${HEART_RATE_SERVICE_UUID}`);
  const [scanResults, setScanResults] = useState<BLEDevice[]>([]);
  const [connectedDeviceId, setConnectedDeviceId] = useState<string | null>(null);
  const [deviceIsConnected, setDeviceIsConnected] = useState(false);
  const [connectedDeviceServiceUUIDs, setConnectedDeviceServiceUUIDs] = useState<string[]>([]);
  const [connectedDeviceCharacteristics, setConnectedDeviceCharacteristics] = useState<Record<string, string[]>>({});
  const [bleNotificationSubscription, setBleNotificationSubscription] = useState<boolean>(false);
  const [hrNotificationSubscription, setHrNotificationSubscription] = useState<boolean>(false);
  const [logs, setLogs] = useState<string[]>([]);
  const bleModule = useRef(createBle({
    onEnabledChange: (enabled) => setIsEnabled(enabled),
  }));
  const ble = bleModule.current;

  useLayoutEffect(() => {
    let stateSubscription: Subscription | null = null;
    let unmounted = false;
    requestPermissionsAndroid().then(async (granted) => {
      if (!granted) logMessage('Bluetooth permissions not granted');
      await requestBluetoothEnable();
      if (!unmounted) stateSubscription = ble.mount();
    });
    const unsub = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        // Synchronous; the state subscription reports later changes.
        setIsEnabled(ble.instance.isBluetoothEnabled());
      }
    });
    return () => {
      unmounted = true;
      stateSubscription?.remove();
      unsub.remove();
      disconnectDevice();
      resetScannedDevices();
      stopScan();
      clearLogs();
    };
  }, []);

  const requestBluetoothEnable = async () => {
    if (Platform.OS !== 'android') {
      return true;
    }
    try {
      await ble.instance.requestBluetoothEnable();
      logMessage('requestBluetoothEnable', 'ok');
      return true;
    } catch (e) {
      console.error(e);
      logMessage('requestBluetoothEnable failed', describeError(e));
      return false;
    }
  };

  /**
   * Android 12 (API 31) and later: BLUETOOTH_SCAN and BLUETOOTH_CONNECT only.
   * app.json sets the plugin's neverForLocation, which declares BLUETOOTH_SCAN
   * with usesPermissionFlags="neverForLocation" and declares the location
   * permissions only up to API 30, so requesting location there would always
   * be denied. Android 11 and older: scanning needs ACCESS_FINE_LOCATION.
   */
  const requestPermissionsAndroid = async () => {
    if (Platform.OS !== 'android') {
      return true;
    }
    const apiLevel = parseInt(Platform.Version.toString(), 10);
    logMessage(`API level: ${apiLevel}`);
    if (apiLevel < 31) {
      const result = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION);
      return result === PermissionsAndroid.RESULTS.GRANTED;
    }
    const result = await PermissionsAndroid.requestMultiple([
      PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
      PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
    ]);
    return (
      result[PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN] === PermissionsAndroid.RESULTS.GRANTED &&
      result[PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT] === PermissionsAndroid.RESULTS.GRANTED
    );
  };

  const startScan = async () => {
    ble.instance.startScan({
      serviceUUIDs: scanServiceUUIDs.replaceAll(' ', '').split(',').filter((uuid) => uuid.length > 0),
      rssiThreshold: -100,
      allowDuplicates: false,
    }, (device) => {
      logMessage(`Scan result: ${device.id} with Manufacturer Data: ${JSON.stringify(device.manufacturerData)}`);
      setScanResults((prev) => {
        const index = prev.findIndex((d) => d.id === device.id);
        if (index === -1) {
          return [...prev, device];
        }
        prev[index] = device;
        return prev;
      });
    }, (error) => {
      console.error(error);
      logMessage(`Scan error: ${describeError(error)}`);
    });
    logMessage('Scan started');
    setIsScanning(true);
  };

  const stopScan = () => {
    ble.instance.stopScan();
    logMessage('Scan stopped');
    setIsScanning(false);
  };

  const resetScannedDevices = () => {
    setScanResults([]);
  };

  const getConnectedDevices = () => {
    const devices = ble.instance.getConnectedDevices([HEART_RATE_SERVICE_UUID, BATTERY_SERVICE_UUID]);
    setScanResults(devices);
  };

  const onDisconnected = async (deviceId: string, interrupted: boolean) => {
    if (interrupted) {
      logMessage('Disconnected because connection was interrupted');
    } else {
      logMessage('Disconnected intentionally');
    }
    // The link's subscriptions ended with it (their onEnded already ran);
    // remove() on an ended subscription resolves without doing anything.
    await unlistenToBleNotifications();
    await unlistenToHrNotifications();
    checkConnection(deviceId);
    setConnectedDeviceServiceUUIDs([]);
    setConnectedDeviceCharacteristics({});
    setConnectedDeviceId(null);
  }

  const connectDevice = async (deviceId: string) => {
    try {
      clearLogs();
      setConnectedDeviceId(null);
      setConnectedDeviceServiceUUIDs([]);
      stopScan();
      logMessage(`1 Connecting to ${deviceId}`);
      const connectedId = await ble.instance.connect(deviceId, {}, onDisconnected);
      setConnectedDeviceId(connectedId);
      checkConnection(connectedId);
      logMessage(`2 Connected to ${connectedId}`);
      // Discovers the services and their characteristics, then lists them.
      const servicesWithCharacteristics = await ble.instance.getServicesWithCharacteristics(connectedId);
      logMessage(`3 Got ${servicesWithCharacteristics.length} services for ${connectedId}`);
      setConnectedDeviceServiceUUIDs(servicesWithCharacteristics.map((s) => s.uuid));
      resetScannedDevices();
      servicesWithCharacteristics.map(async (s) => {
        setConnectedDeviceCharacteristics((prev) => {
          prev[s.uuid] = s.characteristics;
          return prev;
        });
      });
      logMessage('Device is connected');
    } catch (e) {
      console.error(e);
      logMessage('Connect failed', describeError(e));
    }
  };

  const findAndConnect = async () => {
    try {
      logMessage('Finding device');
      const connectedId = await ble.instance.findAndConnect(Platform.select({
        ios: '7F89D88A-1915-DBC3-B712-0AF59D16840C',
        android: 'ca:91:21:0e:0d:5a'.toUpperCase(),
        default: '7F89D88A-1915-DBC3-B712-0AF59D16840C',
      }), {
        onDisconnect: onDisconnected,
      });
      logMessage('Found and connected', connectedId);
      setConnectedDeviceId(connectedId);
      checkConnection(connectedId);
      const servicesWithCharacteristics = await ble.instance.getServicesWithCharacteristics(connectedId);
      logMessage(JSON.stringify(servicesWithCharacteristics));
      setConnectedDeviceServiceUUIDs(servicesWithCharacteristics.map((s) => s.uuid));
      resetScannedDevices();
      servicesWithCharacteristics.map(async (s) => {
        setConnectedDeviceCharacteristics((prev) => {
          prev[s.uuid] = s.characteristics;
          return prev;
        });
      });
      logMessage('Device is connected');
    } catch (e) {
      console.error(e);
      logMessage('Find and connect failed', describeError(e));
    }
  };

  const disconnectDevice = async () => {
    if (!connectedDeviceId) {
      return;
    }
    if (!deviceIsConnected) {
      return;
    }
    // onDisconnected runs from the disconnect callback, with interrupted = false.
    await ble.instance.disconnect(connectedDeviceId);
  }

  const readCharacteristic = (serviceId: string, characteristicId: string) => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    return ble.instance.readCharacteristic(connectedDeviceId, serviceId, characteristicId);
  }

  const readRSSI = async () => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    const rssi = await ble.instance.readRSSI(connectedDeviceId);
    logMessage('RSSI', rssi);
  }

  const readBatteryLevel = async () => {
    const batteryLevel = await readCharacteristic(
      BATTERY_SERVICE_UUID,
      BATTERY_CHARACTERISTIC_LEVEL_UUID,
    );
    logMessage('Battery Level', new Uint8Array(batteryLevel)[0]);
  };

  const readBodySensorLocation = async () => {
    const [bodySensorLocation] = new Uint8Array(await readCharacteristic(
      HEART_RATE_SERVICE_UUID,
      BODY_SENSOR_LOCATION_UUID,
    ));
    const map = ['Other', 'Chest', 'Wrist', 'Finger', 'Hand', 'Earlobe', 'Foot'];
    const key = bodySensorLocation !== undefined && map[bodySensorLocation] ? map[bodySensorLocation] : 'Unknown';
    logMessage('Body Sensor Location', key);
  }

  const requestMtu = async () => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    try {
      const mtu = await ble.instance.requestMTU(connectedDeviceId, 517);
      logMessage('MTU', mtu);
    } catch (e) {
      logMessage('MTU request failed', describeError(e));
    }
  };

  const requestConnectionPriority = async (priority: AndroidConnectionPriority) => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    try {
      await ble.instance.requestConnectionPriority(connectedDeviceId, priority);
      logMessage(`Connection Priority (${priority})`, 'accepted');
    } catch (e) {
      logMessage(`Connection Priority (${priority})`, describeError(e));
    }
  };

  const describeError = (e: unknown) => {
    if (e instanceof BleError) {
      return `${e.errorCode} ${e.message}${e.nativeStatus !== undefined ? ` (native status ${e.nativeStatus})` : ''}`;
    }
    return String(e);
  };

  const stringFromBytes = (value: ArrayBuffer) => {
    return String.fromCharCode(...new Uint8Array(value)).replace(/\0/g, '');
  }

  const hexFromBytes = (value: ArrayBuffer) => {
    return Array.from(new Uint8Array(value), (b) => b.toString(16).padStart(2, '0').toUpperCase()).join(':');
  };

  const readFirmwareVersion = async () => {
    const fVersion = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_FIRMWARE_UUID,
    );
    logMessage('Firmware Version', stringFromBytes(fVersion));
  };

  const readHardwareVersion = async () => {
    const hVersion = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_HARDWARE_UUID,
    );
    logMessage('Hardware Version', stringFromBytes(hVersion));
  };

  const readSoftwareVersion = async () => {
    const sVersion = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_SOFTWARE_UUID,
    );
    logMessage('Software Version', stringFromBytes(sVersion));
  };

  const readModelNumber = async () => {
    const modelNumber = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_MODEL_UUID,
    );
    logMessage('Model Number', stringFromBytes(modelNumber));
  };

  const readManufacturer = async () => {
    const manufacturer = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_MANUFACTURER_UUID,
    )
    logMessage('Manufacturer', stringFromBytes(manufacturer));
  };

  const readSystemid = async () => {
    const systemid = await readCharacteristic(
      PROFILE_SERVICE_UUID,
      PROFILE_SYSTEMID_UUID
    );
    logMessage('System ID', hexFromBytes(systemid));
  }

  const logMessage = (...message: (string | number)[]) => {
    const date = new Date().toLocaleTimeString('de-DE');
    setLogs((prev) => [...prev, `${date} - ${message.join(' ')}`]);
  }

  const clearLogs = () => {
    setLogs([]);
  }

  const sendCommand = async (command: 'enable-led' | 'disable-led') => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    
    console.log('Will send command', command);

    switch (command) {
      case 'enable-led':
        let enableLedCommand = [0x00, 0x1f, 0x01];
        console.log('Will enable led with command:', 0x0e, enableLedCommand);
        enableLedCommand = ble.buildCommand(0x0e, ...enableLedCommand);
        console.log('Will enable led with command:', 0x0e, enableLedCommand);
        const result = await ble.instance.writeCharacteristic(connectedDeviceId, CUSTOM_SERVICE_UUID, TX_CHAR_UUID, enableLedCommand);
        logMessage('Led enabled', hexFromBytes(result));
        break;
      case 'disable-led':
        let disableLedCommand = [0x00, 0x1f, 0x00];
        disableLedCommand = ble.buildCommand(0x0e, ...disableLedCommand);
        console.log('Will disable led with command:', 0x0e, disableLedCommand);
        const disResult = await ble.instance.writeCharacteristic(connectedDeviceId, CUSTOM_SERVICE_UUID, TX_CHAR_UUID, disableLedCommand);
        logMessage('Led disabled', hexFromBytes(disResult));
        break;
      default:
        break;
    }
  };

  const listenToBleNotifications = async () => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    await unlistenToBleNotifications();
    const sub = await ble.instance.subscribeToCharacteristic(connectedDeviceId, CUSTOM_SERVICE_UUID, RX_CHAR_UUID, (data) => {
      logMessage('Received data', hexFromBytes(data));
    }, (error) => {
      // Ended without remove(): link lost, disconnect(), timeout or services changed.
      logMessage('Notifications ended', describeError(error));
      if (unsubscribeRx === sub.remove) {
        unsubscribeRx = null;
        setBleNotificationSubscription(false);
      }
    });
    logMessage('Subscribed to notifications');
    unsubscribeRx = sub.remove;
    setBleNotificationSubscription(true);
  };

  const unlistenToBleNotifications = async () => {
    const remove = unsubscribeRx;
    if (!remove) return;
    unsubscribeRx = null;
    setBleNotificationSubscription(false);
    await remove();
    logMessage('Unsubscribed from notifications');
  }

  const listenToHrNotifications = async () => {
    if (!connectedDeviceId) {
      throw new Error('No device connected');
    }
    if (unsubscribeHr) {
      logMessage('Already listening to heart rate, subscribing again');
      await unlistenToHrNotifications();
    }
    const sub = await ble.instance.subscribeToCharacteristic(connectedDeviceId, HEART_RATE_SERVICE_UUID, HEART_RATE_MEASUREMENT_UUID, (data) => {
      const bytes = new Uint8Array(data);
      const [type, hr] = bytes;
      logMessage('Heart Rate', hr);
      if (type === 0) return;
      if (type === 0x10) {
        const flags = bytes[0];
        const rrPresent = (flags & 0b00010000) !== 0; // Bit4 = RR-Intervalle vorhanden

        let offset = 1;
        if ((flags & 0b00000001) !== 0) {
          // Heart Rate 16-bit
          offset += 2;
        } else {
          // Heart Rate 8-bit
          offset += 1;
        }

        // Energy Expended überspringen, falls vorhanden
        if ((flags & 0b00001000) !== 0) {
          offset += 2;
        }

        const rrMs: number[] = [];
        if (rrPresent) {
          for (let i = offset; i + 1 < bytes.length; i += 2) {
            const rr = bytes[i] | (bytes[i + 1] << 8); // little endian
            rrMs.push(Number(((rr * 1000) / 1024).toFixed(0)));
          }
        }

        logMessage('RR-Intervals', ...rrMs);
      }
    }, (error) => {
      // Ended without remove(): link lost, disconnect(), timeout or services changed.
      logMessage('Heart rate ended', describeError(error));
      if (unsubscribeHr === sub.remove) {
        unsubscribeHr = null;
        setHrNotificationSubscription(false);
      }
    });
    logMessage('Subscribed to heart rate');
    unsubscribeHr = sub.remove;
    setHrNotificationSubscription(true);
  };

  const unlistenToHrNotifications = async () => {
    const remove = unsubscribeHr;
    if (!remove) return;
    unsubscribeHr = null;
    setHrNotificationSubscription(false);
    await remove();
    logMessage('Unsubscribed from heart rate');
  };

  const checkSubscriptions = () => {
    if (!connectedDeviceId) {
      logMessage('No connected device');
      return;
    }
    const hrSubscribed = ble.instance.isSubscribedToCharacteristic(
      connectedDeviceId, HEART_RATE_SERVICE_UUID, HEART_RATE_MEASUREMENT_UUID
    );
    logMessage('HR subscribed:', String(hrSubscribed));
    const rxSubscribed = ble.instance.isSubscribedToCharacteristic(
      connectedDeviceId, CUSTOM_SERVICE_UUID, RX_CHAR_UUID
    );
    logMessage('RX subscribed:', String(rxSubscribed));
  };

  const checkConnection = (deviceId = connectedDeviceId) => {
    if (!deviceId) {
      logMessage('No connected device');
      return false;
    }
    const isConnected = ble.instance.isConnected(deviceId);
    setDeviceIsConnected(isConnected);
    logMessage(`Device ${deviceId} is ${isConnected ? 'connected' : 'disconnected'}`);
    return isConnected;
  };

  return (
    <>
    <StatusBar style="auto" />
      <ScrollView
        style={[styles.container, { padding: 16 }]}
        nestedScrollEnabled
      >
        <SafeAreaView>
            <Text>Ble Enabled: {isEnabled.toString()}</Text>
            {!isEnabled && (
              <>
                <TouchableOpacity style={styles.button} onPress={requestBluetoothEnable}>
                  <Text>Enable Bluetooth</Text>
                </TouchableOpacity>
                <TouchableOpacity style={styles.button} onPress={() => ble.instance.openSettings().catch((e) => { console.error(e) })}>
                  <Text>Open Bluetooth Settings</Text>
                </TouchableOpacity>
              </>
            )}
            {isEnabled && (
              <>
                {!connectedDeviceId && (
                  <>
                  <Text>Scan Service UUIDs:</Text>
                  <TextInput style={{ borderWidth: 1, padding: 3 }} value={scanServiceUUIDs} onChangeText={setScanServiceUUIDs}></TextInput>
                  {isScanning ? (
                    <TouchableOpacity style={styles.button} onPress={stopScan}>
                      <Text>Stop Scan</Text>
                    </TouchableOpacity>
                  ) : (
                    <TouchableOpacity style={styles.button} onPress={startScan}>
                      <Text>Start Scan</Text>
                    </TouchableOpacity>
                  )}
                  <TouchableOpacity style={styles.button} onPress={findAndConnect}>
                    <Text>Find And Connect Device</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={styles.button} onPress={getConnectedDevices}>
                    <Text>Get connected devices</Text>
                  </TouchableOpacity>
                  {scanResults.length > 0 && (
                    <View style={{ borderTopWidth: 1, borderBottomWidth: 1, paddingVertical: 16 }}>
                      <Text>Scanned Devices:</Text>
                      <TouchableOpacity style={styles.button} onPress={resetScannedDevices}>
                        <Text>Reset Scanned Devices</Text>
                      </TouchableOpacity>
                      {scanResults.map((device) => (
                        <TouchableOpacity key={device.id} style={{ padding: 8, backgroundColor: '#f4f4f4ff', borderRadius: 4 }} onPress={() => connectDevice(device.id)}>
                          <Text>ID: {device.id}</Text>
                          <Text>Name: {device.name}</Text>
                          <Text>RSSI: {device.rssi}</Text>
                          <Text selectable>Manufacturer Data: {JSON.stringify(device.manufacturerData)}</Text>
                          <Text>Service UUIDs: {JSON.stringify(device.serviceUUIDs)}</Text>
                          <Text>Is Connectable: {device.isConnectable.toString()}</Text>
                          <Text>Tap to connect</Text>
                        </TouchableOpacity>
                      ))}
                    </View>
                  )}
                  </>
                )}
                {connectedDeviceId && (
                  <>
                    <Text style={{ marginTop: 16 }}>Connected Device:</Text>
                    <View style={{ padding: 8, marginTop: 8, backgroundColor: '#f4f4f4ff', borderRadius: 4, }}>
                      <Text selectable>ID: {connectedDeviceId}</Text>
                      <Text>Is connected: {deviceIsConnected.toString()}</Text>
                      <Text style={{ borderTopWidth: 1 }}>Services:</Text>
                      {connectedDeviceServiceUUIDs.map((s) => (
                        <View key={s} style={{ paddingTop: 2, borderBottomWidth: 1 }}>
                          <Text>Service: {s}</Text>
                          <Text>Characteristics:</Text>
                          {connectedDeviceCharacteristics[s]?.map((c) => (
                            <Text key={c}>{c}</Text>
                          ))}
                          {s === BATTERY_SERVICE_UUID && connectedDeviceCharacteristics[s]?.includes(BATTERY_CHARACTERISTIC_LEVEL_UUID) && (
                            <TouchableOpacity style={styles.button} onPress={readBatteryLevel}>
                              <Text>Read Battery Level</Text>
                            </TouchableOpacity>
                          )}
                          {s === CUSTOM_SERVICE_UUID && connectedDeviceCharacteristics[s]?.includes(TX_CHAR_UUID) && (
                            <>
                              <TouchableOpacity style={styles.button} onPress={() => sendCommand('enable-led')}>
                                <Text>Enable LED</Text>
                              </TouchableOpacity>
                              <TouchableOpacity style={styles.button} onPress={() => sendCommand('disable-led')}>
                                <Text>Disable LED</Text>
                              </TouchableOpacity>
                            </>
                          )}
                          {s === CUSTOM_SERVICE_UUID && connectedDeviceCharacteristics[s]?.includes(RX_CHAR_UUID) && (
                            <>
                              {!bleNotificationSubscription && (
                                <TouchableOpacity style={styles.button} onPress={listenToBleNotifications}>
                                  <Text>Listen to BLE Notifications</Text>
                                </TouchableOpacity>
                              )}
                              {bleNotificationSubscription && (
                                <TouchableOpacity style={styles.button} onPress={unlistenToBleNotifications}>
                                  <Text>Stop Listening to BLE Notifications</Text>
                                </TouchableOpacity>
                              )}
                              {!bleNotificationSubscription && !hrNotificationSubscription && (
                                <TouchableOpacity style={styles.button} onPress={async () => {
                                  await listenToBleNotifications();
                                  await listenToHrNotifications();
                                }}>
                                  <Text>Listen to HR and Custom Notifications</Text>
                                </TouchableOpacity>
                              )}
                            </>
                          )}
                          {s === HEART_RATE_SERVICE_UUID && connectedDeviceCharacteristics[s]?.includes(HEART_RATE_MEASUREMENT_UUID) && (
                            <>
                              {!hrNotificationSubscription && (
                                <TouchableOpacity style={styles.button} onPress={listenToHrNotifications}>
                                  <Text>Listen to HR Notifications</Text>
                                </TouchableOpacity>
                              )}
                              {hrNotificationSubscription && (
                                <>
                                  <TouchableOpacity style={styles.button} onPress={listenToHrNotifications}>
                                    <Text>Try override listen to HR Notifications</Text>
                                  </TouchableOpacity>
                                  <TouchableOpacity style={styles.button} onPress={unlistenToHrNotifications}>
                                    <Text>Stop Listening to HR Notifications</Text>
                                  </TouchableOpacity>
                                </>
                              )}
                              <TouchableOpacity style={styles.button} onPress={readBodySensorLocation}>
                                <Text>Read Body Sensor Location</Text>
                              </TouchableOpacity>
                            </>
                          )}
                          {s === PROFILE_SERVICE_UUID && (
                            <>
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_FIRMWARE_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readFirmwareVersion}>
                                  <Text>Read Firmware Version</Text>
                                </TouchableOpacity>
                              )}
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_HARDWARE_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readHardwareVersion}>
                                  <Text>Read Hardware Version</Text>
                                </TouchableOpacity>
                              )}
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_SOFTWARE_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readSoftwareVersion}>
                                  <Text>Read Software Version</Text>
                                </TouchableOpacity>
                              )}
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_MODEL_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readModelNumber}>
                                  <Text>Read Model Number</Text>
                                </TouchableOpacity>
                              )}
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_MANUFACTURER_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readManufacturer}>
                                  <Text>Read Manufacturer</Text>
                                </TouchableOpacity>
                              )}
                              {connectedDeviceCharacteristics[s]?.includes(PROFILE_SYSTEMID_UUID) && (
                                <TouchableOpacity style={styles.button} onPress={readSystemid}>
                                  <Text>Read System ID</Text>
                                </TouchableOpacity>
                              )}
                            </>
                          )}
                        </View>
                      ))}
                      <TouchableOpacity style={styles.button} onPress={requestMtu}>
                        <Text>Request MTU</Text>
                      </TouchableOpacity>
                      <TouchableOpacity style={styles.button} onPress={() => requestConnectionPriority(AndroidConnectionPriority.High)}>
                        <Text>Priority: High (Android)</Text>
                      </TouchableOpacity>
                      <TouchableOpacity style={styles.button} onPress={() => requestConnectionPriority(AndroidConnectionPriority.Balanced)}>
                        <Text>Priority: Balanced (Android)</Text>
                      </TouchableOpacity>
                      <TouchableOpacity style={styles.button} onPress={() => requestConnectionPriority(AndroidConnectionPriority.LowPower)}>
                        <Text>Priority: Low Power (Android)</Text>
                      </TouchableOpacity>
                      <TouchableOpacity style={styles.button} onPress={readRSSI}>
                        <Text>Read RSSI</Text>
                      </TouchableOpacity>
                      <TouchableOpacity style={styles.button} onPress={checkSubscriptions}>
                        <Text>Check Subscriptions</Text>
                      </TouchableOpacity>
                      {deviceIsConnected && (
                        <TouchableOpacity style={styles.button} onPress={disconnectDevice}>
                          <Text>Disconnect</Text>
                        </TouchableOpacity>
                      )}
                      {!deviceIsConnected && (
                        <TouchableOpacity style={styles.button} onPress={() => {
                          connectDevice(connectedDeviceId);
                        }}>
                          <Text>Connect</Text>
                        </TouchableOpacity>
                      )}
                    </View>
                  </>
                )}
              </>
            )}
            <TouchableOpacity style={styles.button} onPress={() => checkConnection()}>
              <Text>Check Connection</Text>
            </TouchableOpacity>
            {(logs.length > 0) && (
              <View>
                <Text style={{ marginTop: 16 }}>Logs:</Text>
                <ScrollView style={{ marginTop: 8, backgroundColor: '#f4f4f4ff', borderRadius: 4, padding: 8, maxHeight: 200 }} nestedScrollEnabled>
                  {logs.sort((a, b) => {
                    return b.toLocaleLowerCase().localeCompare(a.toLocaleLowerCase());
                  }).map((log, i) => (
                    <Text key={i} style={{ fontSize: 11, fontFamily: 'monospace', color: '#444', borderBottomWidth: i === logs.length - 1 ? 0 : 1, padding: 6 }} selectable>{log}</Text>
                  ))}
                </ScrollView>
                <TouchableOpacity style={styles.button} onPress={clearLogs}>
                  <Text>Clear Logs</Text>
                </TouchableOpacity>
              </View>
            )}
            <View style={{ height: 32 }} />
        </SafeAreaView>
      </ScrollView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    // paddingHorizontal: 0,
  },
  button: {
    padding: 8,
    backgroundColor: '#999',
    borderRadius: 4,
    alignItems: 'center',
    marginVertical: 8,
  },
});
