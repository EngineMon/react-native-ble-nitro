import type { AndroidConfig, IOSConfig } from '@expo/config-plugins';
import { applyAndroidManifest, applyInfoPlist } from '../src/withBleNitro';

type Manifest = AndroidConfig.Manifest.AndroidManifest;
type Attributes = Record<string, string | undefined>;

const FINE = 'android.permission.ACCESS_FINE_LOCATION';
const COARSE = 'android.permission.ACCESS_COARSE_LOCATION';
const SCAN = 'android.permission.BLUETOOTH_SCAN';
const BACKGROUND = 'android.permission.ACCESS_BACKGROUND_LOCATION';
const ADVERTISE = 'android.permission.BLUETOOTH_ADVERTISE';
const BLE_FEATURE = 'android.hardware.bluetooth_le';

function manifestWith(permissions: Attributes[] = [], features: Attributes[] = []): Manifest {
  return {
    manifest: {
      $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
      'uses-permission': permissions.map(($) => ({ $ })),
      'uses-feature': features.map(($) => ({ $ })),
    },
  } as unknown as Manifest;
}

/** The attributes of the one entry named `name`; fails when there are none or several. */
function permission(manifest: Manifest, name: string): Attributes | undefined {
  const entries = (manifest.manifest['uses-permission'] ?? []).filter((e) => e.$['android:name'] === name);
  expect(entries.length).toBeLessThanOrEqual(1);
  return entries[0]?.$ as Attributes | undefined;
}

function bleFeatureRequired(manifest: Manifest): (string | undefined)[] {
  return (manifest.manifest['uses-feature'] ?? [])
    .filter((f) => f.$['android:name'] === BLE_FEATURE)
    .map((f) => (f.$ as Attributes)['android:required']);
}

describe('applyAndroidManifest', () => {
  test('neverForLocation true caps the location permissions it adds and flags BLUETOOTH_SCAN', () => {
    const manifest = manifestWith();
    applyAndroidManifest(manifest, { neverForLocation: true });

    expect(permission(manifest, SCAN)?.['android:usesPermissionFlags']).toBe('neverForLocation');
    expect(permission(manifest, FINE)?.['android:maxSdkVersion']).toBe('30');
    expect(permission(manifest, COARSE)?.['android:maxSdkVersion']).toBe('30');
  });

  test('turning neverForLocation off again without a clean prebuild removes the flag and widens location', () => {
    const manifest = manifestWith();
    applyAndroidManifest(manifest, { neverForLocation: true });
    applyAndroidManifest(manifest, { neverForLocation: false });

    expect(permission(manifest, SCAN)).not.toHaveProperty('android:usesPermissionFlags');
    expect(permission(manifest, FINE)).not.toHaveProperty('android:maxSdkVersion');
    expect(permission(manifest, COARSE)).not.toHaveProperty('android:maxSdkVersion');
  });

  test('removing neverForLocation keeps any other permission flag', () => {
    const manifest = manifestWith([{ 'android:name': SCAN, 'android:usesPermissionFlags': 'otherFlag|neverForLocation' }]);
    applyAndroidManifest(manifest, { neverForLocation: false });

    expect(permission(manifest, SCAN)?.['android:usesPermissionFlags']).toBe('otherFlag');
  });

  test('neverForLocation never caps a location permission declared elsewhere', () => {
    const manifest = manifestWith([{ 'android:name': FINE }]);
    applyAndroidManifest(manifest, { neverForLocation: true });

    expect(permission(manifest, FINE)).not.toHaveProperty('android:maxSdkVersion');
    expect(permission(manifest, COARSE)?.['android:maxSdkVersion']).toBe('30');
  });

  test('without neverForLocation an existing cap on location is removed', () => {
    const manifest = manifestWith([{ 'android:name': FINE, 'android:maxSdkVersion': '30' }]);
    applyAndroidManifest(manifest, {});

    expect(permission(manifest, FINE)).not.toHaveProperty('android:maxSdkVersion');
  });

  test('legacy Bluetooth permissions are capped at API 30, also when declared elsewhere', () => {
    const manifest = manifestWith([{ 'android:name': 'android.permission.BLUETOOTH' }]);
    applyAndroidManifest(manifest, {});

    expect(permission(manifest, 'android.permission.BLUETOOTH')?.['android:maxSdkVersion']).toBe('30');
    expect(permission(manifest, 'android.permission.BLUETOOTH_ADMIN')?.['android:maxSdkVersion']).toBe('30');
  });

  test('isBackgroundEnabled adds background location capped at API 30 and keeps an existing declaration', () => {
    const added = manifestWith();
    applyAndroidManifest(added, { isBackgroundEnabled: true });
    expect(permission(added, BACKGROUND)?.['android:maxSdkVersion']).toBe('30');

    const existing = manifestWith([{ 'android:name': BACKGROUND }]);
    applyAndroidManifest(existing, { isBackgroundEnabled: true });
    expect(permission(existing, BACKGROUND)).not.toHaveProperty('android:maxSdkVersion');

    const off = manifestWith();
    applyAndroidManifest(off, {});
    expect(permission(off, BACKGROUND)).toBeUndefined();
  });

  test('BLUETOOTH_ADVERTISE is declared only with androidAdvertisingEnabled', () => {
    const off = manifestWith();
    applyAndroidManifest(off, {});
    expect(permission(off, ADVERTISE)).toBeUndefined();

    const on = manifestWith();
    applyAndroidManifest(on, { androidAdvertisingEnabled: true });
    expect(permission(on, ADVERTISE)).toBeDefined();
  });

  test('androidBleRequired sets the bluetooth_le feature both ways, also on an existing entry', () => {
    const manifest = manifestWith([], [{ 'android:name': BLE_FEATURE, 'android:required': 'true' }]);
    applyAndroidManifest(manifest, {});
    expect(bleFeatureRequired(manifest)).toEqual(['false']);

    applyAndroidManifest(manifest, { androidBleRequired: true });
    expect(bleFeatureRequired(manifest)).toEqual(['true']);
  });

  test('applying twice declares every permission once', () => {
    const manifest = manifestWith();
    const props = { neverForLocation: true, isBackgroundEnabled: true, androidAdvertisingEnabled: true };
    applyAndroidManifest(manifest, props);
    const once = JSON.stringify(manifest);
    applyAndroidManifest(manifest, props);

    expect(JSON.stringify(manifest)).toBe(once);
  });
});

describe('applyInfoPlist', () => {
  test('an absent message keeps the one Info.plist has, else sets the default; false leaves it alone', () => {
    const existing: IOSConfig.InfoPlist = { NSBluetoothAlwaysUsageDescription: 'Ours' };
    applyInfoPlist(existing, {});
    expect(existing.NSBluetoothAlwaysUsageDescription).toBe('Ours');

    const empty: IOSConfig.InfoPlist = {};
    applyInfoPlist(empty, {});
    expect(empty.NSBluetoothAlwaysUsageDescription).toBe('Allow $(PRODUCT_NAME) to connect to bluetooth devices');

    const untouched: IOSConfig.InfoPlist = {};
    applyInfoPlist(untouched, { bluetoothAlwaysPermission: false });
    expect(untouched).not.toHaveProperty('NSBluetoothAlwaysUsageDescription');
  });

  test('background modes are added once each, existing ones kept, unknown values skipped', () => {
    const plist: IOSConfig.InfoPlist = { UIBackgroundModes: ['audio', 'bluetooth-central'] };
    applyInfoPlist(plist, { modes: ['central', 'peripheral', 'central', 'bogus' as 'central'] });

    expect(plist.UIBackgroundModes).toEqual(['audio', 'bluetooth-central', 'bluetooth-peripheral']);
  });

  test('turning iOSLazyInit off again without a clean prebuild removes BLENitroLazyInit', () => {
    const plist: IOSConfig.InfoPlist = {};
    applyInfoPlist(plist, { iOSLazyInit: true });
    expect(plist.BLENitroLazyInit).toBe(true);

    applyInfoPlist(plist, {});
    expect(plist).not.toHaveProperty('BLENitroLazyInit');
  });
});
