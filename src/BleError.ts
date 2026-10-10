import { BleErrorCode, type BleError as NativeBleError } from './specs/NativeBleNitro.nitro';

export { BleErrorCode };

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
  /** The canonical id of the device the failed operation was for, if any. */
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

export function bleErrorFromNative(error: NativeBleError, deviceId: string | undefined): BleError {
  return new BleError(error.code, error.message, { nativeStatus: error.nativeStatus, deviceId });
}

/**
 * The BleError for anything thrown during an operation on `deviceId`: a
 * BleError the validation threw (given the device when it names none), or an
 * exception a native call threw (a bug or an OS exception), as UnknownError
 * keeping the exception as `cause`.
 */
export function bleErrorFromThrown(thrown: unknown, deviceId: string | undefined): BleError {
  if (thrown instanceof BleError) {
    if (thrown.deviceId !== undefined || deviceId === undefined) return thrown;
    return new BleError(thrown.errorCode, thrown.message, {
      nativeStatus: thrown.nativeStatus,
      deviceId,
      cause: thrown.cause,
    });
  }
  const message = thrown instanceof Error ? thrown.message : String(thrown);
  return new BleError(BleErrorCode.UnknownError, message, { deviceId, cause: thrown });
}

export function destroyedError(deviceId: string | undefined): BleError {
  return new BleError(BleErrorCode.BluetoothManagerDestroyed, 'The BleNitroManager was destroyed', { deviceId });
}
