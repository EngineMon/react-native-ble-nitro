import { BleError, BleErrorCode } from './BleError';

/** 16- and 32-bit UUIDs: values on the Bluetooth Base UUID (Bluetooth Core Specification Vol 3 Part B §2.5.1). */
const SHORT_GATT_UUID = /^[0-9a-f]{4}(?:[0-9a-f]{4})?$/;
const BLUETOOTH_BASE_UUID_SUFFIX = '-0000-1000-8000-00805f9b34fb';
const DASHLESS_GATT_UUID = /^[0-9a-f]{32}$/;
const CANONICAL_GATT_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * The lowercase 36-character form of a GATT UUID, or null when `uuid` is none
 * of the accepted forms: exactly 4 or 8 hex digits (a 16- or 32-bit UUID,
 * placed on the Bluetooth Base UUID), 32 hex digits, or the 8-4-4-4-12 form,
 * in any letter case.
 *
 * Strict on purpose: padding or passing on anything else would address
 * another attribute than the caller meant, or fail differently on each
 * platform.
 */
export function parseGattUUID(uuid: unknown): string | null {
  if (typeof uuid !== 'string') return null;
  const lower = uuid.toLowerCase();
  if (SHORT_GATT_UUID.test(lower)) return `${lower.padStart(8, '0')}${BLUETOOTH_BASE_UUID_SUFFIX}`;
  if (CANONICAL_GATT_UUID.test(lower)) return lower;
  if (DASHLESS_GATT_UUID.test(lower)) {
    return `${lower.slice(0, 8)}-${lower.slice(8, 12)}-${lower.slice(12, 16)}-${lower.slice(16, 20)}-${lower.slice(20)}`;
  }
  return null;
}

/** A UUID the caller passed, in its lowercase 36-character form; anything else throws InvalidIdentifiers. */
export function requireGattUUID(uuid: unknown): string {
  const parsed = parseGattUUID(uuid);
  if (parsed === null) {
    throw new BleError(
      BleErrorCode.InvalidIdentifiers,
      `Invalid GATT UUID ${typeof uuid === 'string' ? `"${uuid}"` : `of type ${typeof uuid}`}: expected 4, 8 or 32 hex digits, or the 8-4-4-4-12 form`
    );
  }
  return parsed;
}

/**
 * A UUID the OS reported (scan results, discovered services), normalized like
 * the caller's. The OS reports only well-formed UUIDs, but a scan or discovery
 * result is not the caller's input, so an odd one is passed on lowercased
 * rather than thrown from a callback the caller can't guard.
 */
export function reportedGattUUID(uuid: string): string {
  return parseGattUUID(uuid) ?? uuid.toLowerCase();
}
