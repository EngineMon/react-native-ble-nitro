/** Conversions between the public JS types and the native (Nitro) ones. */
import { BleError, BleErrorCode, bleErrorFromNative } from './BleError';
import { reportedGattUUID } from './gattUuid';
import {
  AndroidConnectionPriority as NativeAndroidConnectionPriority,
  AndroidScanMode as NativeAndroidScanMode,
  BLEState as NativeBLEState,
  ConnectionEventType as NativeConnectionEventType,
  type BLEDevice as NativeBLEDevice,
  type ConnectionEvent as NativeConnectionEvent,
} from './specs/NativeBleNitro.nitro';
import {
  AndroidConnectionPriority,
  AndroidScanMode,
  BLEState,
  ConnectionEventType,
  type BLEDevice,
  type ConnectionEvent,
} from './types';

export const BLE_STATE_FROM_NATIVE: Record<NativeBLEState, BLEState> = {
  [NativeBLEState.Unknown]: BLEState.Unknown,
  [NativeBLEState.Resetting]: BLEState.Resetting,
  [NativeBLEState.Unsupported]: BLEState.Unsupported,
  [NativeBLEState.Unauthorized]: BLEState.Unauthorized,
  [NativeBLEState.PoweredOff]: BLEState.PoweredOff,
  [NativeBLEState.PoweredOn]: BLEState.PoweredOn,
};

export const SCAN_MODE_TO_NATIVE: Record<AndroidScanMode, NativeAndroidScanMode> = {
  [AndroidScanMode.LowLatency]: NativeAndroidScanMode.LowLatency,
  [AndroidScanMode.Balanced]: NativeAndroidScanMode.Balanced,
  [AndroidScanMode.LowPower]: NativeAndroidScanMode.LowPower,
  [AndroidScanMode.Opportunistic]: NativeAndroidScanMode.Opportunistic,
};

export const CONNECTION_PRIORITY_TO_NATIVE: Record<AndroidConnectionPriority, NativeAndroidConnectionPriority> = {
  [AndroidConnectionPriority.Balanced]: NativeAndroidConnectionPriority.Balanced,
  [AndroidConnectionPriority.High]: NativeAndroidConnectionPriority.High,
  [AndroidConnectionPriority.LowPower]: NativeAndroidConnectionPriority.LowPower,
};

const CONNECTION_EVENT_TYPE_FROM_NATIVE: Record<NativeConnectionEventType, ConnectionEventType> = {
  [NativeConnectionEventType.Connected]: ConnectionEventType.Connected,
  [NativeConnectionEventType.Disconnected]: ConnectionEventType.Disconnected,
  [NativeConnectionEventType.ServicesChanged]: ConnectionEventType.ServicesChanged,
};

/**
 * The form both platforms report device ids in (NativeBleNitro.nitro.ts,
 * "Device ids"): Android MAC addresses are uppercase
 * (BluetoothAdapter.checkBluetoothAddress accepts only that form), iOS
 * peripheral identifiers are UUIDs, whose uuidString is uppercase. Every id
 * this library hands out is in this form, so a caller can key its state by
 * any of them and match the ids of later callbacks and events.
 */
export function canonicalDeviceId(deviceId: string): string {
  return deviceId.toUpperCase();
}

/**
 * The bytes of a write as the ArrayBuffer the native call takes. The native
 * side copies them during the call, so the result may share memory with
 * `data`.
 *
 * - ArrayBuffer: as is.
 * - ArrayBufferView (Uint8Array, a Node-style Buffer, DataView...): exactly the
 *   bytes it views. Its `.buffer` is passed only when the view spans all of
 *   it; otherwise the range is copied, because the buffer holds other bytes
 *   too (a subarray's neighbours, or the shared 8 KB pool a small Buffer is
 *   allocated from) that must not be sent to the device.
 * - number[]: each entry must be an integer from 0 to 255. A Uint8Array would
 *   silently wrap anything else (256 → 0, -1 → 255, 1.5 → 1, NaN → 0) and put
 *   different bytes on the air than the caller wrote.
 *
 * Anything else throws CharacteristicInvalidDataFormat.
 */
export function toWriteBuffer(data: unknown): ArrayBuffer {
  if (data instanceof ArrayBuffer) return data;
  if (ArrayBuffer.isView(data)) {
    const { buffer, byteOffset, byteLength } = data;
    if (buffer instanceof ArrayBuffer && byteOffset === 0 && byteLength === buffer.byteLength) return buffer;
    return new Uint8Array(buffer, byteOffset, byteLength).slice().buffer;
  }
  if (Array.isArray(data)) {
    const bytes = new Uint8Array(data.length);
    for (let index = 0; index < data.length; index++) {
      const value: unknown = data[index];
      if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 255) {
        throw new BleError(
          BleErrorCode.CharacteristicInvalidDataFormat,
          `Write data[${index}] is ${typeof value === 'number' ? value : `of type ${typeof value}`}, not an integer from 0 to 255`
        );
      }
      bytes[index] = value;
    }
    return bytes.buffer;
  }
  throw new BleError(
    BleErrorCode.CharacteristicInvalidDataFormat,
    'Write data must be an ArrayBuffer, an ArrayBufferView or an array of bytes'
  );
}

export function toBleDevice(device: NativeBLEDevice): BLEDevice {
  return {
    id: device.id,
    name: device.name,
    rssi: device.rssi,
    isConnectable: device.isConnectable,
    isConnected: device.isConnected,
    serviceUUIDs: device.serviceUUIDs.map(reportedGattUUID),
    manufacturerData: {
      companyIdentifiers: device.manufacturerData.companyIdentifiers.map((entry) => ({
        id: entry.id,
        data: Array.from(new Uint8Array(entry.data)),
      })),
    },
    serviceData: {
      services: device.serviceData.services.map((entry) => ({
        uuid: reportedGattUUID(entry.uuid),
        data: Array.from(new Uint8Array(entry.data)),
      })),
    },
  };
}

export function toConnectionEvent(event: NativeConnectionEvent): ConnectionEvent {
  return {
    deviceId: event.deviceId,
    type: CONNECTION_EVENT_TYPE_FROM_NATIVE[event.type],
    interrupted: event.interrupted,
    error: event.error && bleErrorFromNative(event.error, event.deviceId),
  };
}
