import {
  AndroidConfig,
  ConfigPlugin,
  IOSConfig,
  WarningAggregator,
  withAndroidManifest,
  withInfoPlist,
} from '@expo/config-plugins';

/*
 * One rule for every permission below: the plugin adds what the library
 * needs and never narrows a declaration that already exists (the app's own,
 * another plugin's, or `android.permissions`). Over-declaring costs at most a
 * permission the user is never asked for; narrowing someone else's
 * declaration (a maxSdkVersion on a location permission the app also uses
 * for other purposes) silently breaks that other feature on newer Android.
 * The legacy Bluetooth permissions are the one exception (see
 * applyAndroidManifest). Attributes and keys this plugin owns outright (the
 * neverForLocation flag, the bluetooth_le feature's `android:required`,
 * `BLENitroLazyInit`) follow the config both ways, on an existing entry too,
 * so turning an option off and prebuilding again without --clean removes
 * what turning it on added.
 */

export interface BleNitroPluginProps {
  /**
   * Android only. Declares what discovering devices from the background
   * needs: `ACCESS_BACKGROUND_LOCATION` with `android:maxSdkVersion="30"`.
   *
   * Android Bluetooth permissions guide: "If your app supports a service and
   * can run on Android 10 (API level 29) or Android 11, you must also declare
   * the ACCESS_BACKGROUND_LOCATION permission to discover Bluetooth devices."
   * The declaration stops at API 30: from Android 12 scanning is governed by
   * `BLUETOOTH_SCAN` (always declared), so users on 12+ are never asked for
   * background location on this option's account. An app that derives
   * location from scan results (no `neverForLocation`) and scans in the
   * background on Android 12+ falls under the platform's background location
   * rules and declares `ACCESS_BACKGROUND_LOCATION` itself; an existing
   * declaration is left as it is.
   *
   * On Android 10-11 it is a runtime permission: the app still requests it,
   * after the foreground location permission is granted. The plugin adds no
   * foreground service; running one is the app's job.
   *
   * Does not touch the `android.hardware.bluetooth_le` feature: working in
   * the background and refusing to install on devices without BLE are
   * separate decisions (see `androidBleRequired`).
   * @default false
   */
  isBackgroundEnabled?: boolean;

  /**
   * Android only. Strongly asserts that the app never derives physical
   * location from Bluetooth scan results (Android Bluetooth permissions
   * guide, "Strongly assert that your app doesn't derive physical location").
   *
   * - true: `BLUETOOTH_SCAN` gets `android:usesPermissionFlags="neverForLocation"`,
   *   and the location permissions this plugin adds stop at API 30, so on
   *   Android 12+ scanning needs only the Nearby devices permission. Android
   *   11 and lower still require location for scanning (the flag doesn't
   *   exist there). Android filters some BLE beacons out of the scan results
   *   of an app with this flag. A location permission declared elsewhere
   *   keeps its declaration: the guide caps location at API 30 only if
   *   "location isn't otherwise needed", and that declaration says it is.
   * - false: `BLUETOOTH_SCAN` carries no neverForLocation flag (one an
   *   earlier prebuild set is removed), and `ACCESS_FINE_LOCATION` and
   *   `ACCESS_COARSE_LOCATION` are declared for every API level (a
   *   maxSdkVersion already on them is removed), because without the flag
   *   Android 12+ delivers scan results only with fine location. Request
   *   both together: Android 12+ ignores a request for fine location alone.
   * @default false
   */
  neverForLocation?: boolean;

  /**
   * iOS `UIBackgroundModes` entries: `central` adds `bluetooth-central`
   * (scan, connect and receive notifications while the app is in the
   * background); `peripheral` adds `bluetooth-peripheral`, which only an app
   * that acts as a peripheral through other code needs (this library is
   * central-only). Other values are ignored with a warning; modes already in
   * Info.plist are kept.
   * @default undefined
   */
  modes?: ('peripheral' | 'central')[];

  /**
   * iOS `NSBluetoothAlwaysUsageDescription`, the text of the Bluetooth
   * permission prompt. iOS terminates an app that uses CoreBluetooth without
   * it. A string sets it. Absent keeps a value Info.plist already has (e.g.
   * from `ios.infoPlist`) and otherwise sets the default. `false` leaves
   * Info.plist alone.
   * @default "Allow $(PRODUCT_NAME) to connect to bluetooth devices"
   */
  bluetoothAlwaysPermission?: string | false;

  /**
   * Android only. Declares `BLUETOOTH_ADVERTISE`, the Android 12+ runtime
   * permission an app needs to make the device discoverable to other
   * Bluetooth devices (advertise). This library is central-only and never
   * advertises: set it only when other code in the app does.
   * @default false
   */
  androidAdvertisingEnabled?: boolean;

  /**
   * Android only. The `android:required` value of
   * `<uses-feature android:name="android.hardware.bluetooth_le">`, set on an
   * existing entry too. `true`: Google Play hides the app from devices
   * without BLE. `false`: it installs everywhere and the app handles missing
   * BLE at runtime. The Android Bluetooth permissions guide: "only set the
   * required attribute to true if your app can't work without the feature."
   * @default false
   */
  androidBleRequired?: boolean;

  /**
   * iOS only. Sets `BLENitroLazyInit` in Info.plist (false removes it): the
   * CBCentralManager is created on the first BLE API call instead of at
   * launch, so the Bluetooth permission prompt doesn't appear at launch.
   * With a restore identifier, state restoration waits for that first call.
   * @default false
   */
  iOSLazyInit?: boolean;
}

const PLUGIN_NAME = 'react-native-ble-nitro';

/** The last API level (Android 11) before the Android 12 Bluetooth permission model. */
const LEGACY_MAX_SDK = '30';

/** Replaced by BLUETOOTH_SCAN / BLUETOOTH_CONNECT from Android 12. */
const LEGACY_BLUETOOTH_PERMISSIONS = [
  'android.permission.BLUETOOTH',
  'android.permission.BLUETOOTH_ADMIN',
];

const BLUETOOTH_SCAN = 'android.permission.BLUETOOTH_SCAN';
const BLUETOOTH_CONNECT = 'android.permission.BLUETOOTH_CONNECT';
const BLUETOOTH_ADVERTISE = 'android.permission.BLUETOOTH_ADVERTISE';
const ACCESS_BACKGROUND_LOCATION = 'android.permission.ACCESS_BACKGROUND_LOCATION';

/** The `android:usesPermissionFlags` value that asserts scans never derive location. */
const NEVER_FOR_LOCATION = 'neverForLocation';

/**
 * Location a scan needs: always on Android 11 and lower, on 12+ unless
 * BLUETOOTH_SCAN is declared neverForLocation. Coarse is declared with fine
 * because an app targeting Android 12+ must request both in one request
 * (the system ignores a request for fine alone), and a permission missing
 * from the manifest is denied without a prompt.
 */
const SCAN_LOCATION_PERMISSIONS = [
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.ACCESS_COARSE_LOCATION',
];

const BLE_FEATURE = 'android.hardware.bluetooth_le';

/** iOS background mode per `modes` value. */
const IOS_BACKGROUND_MODES: Record<NonNullable<BleNitroPluginProps['modes']>[number], string> = {
  central: 'bluetooth-central',
  peripheral: 'bluetooth-peripheral',
};

/** Own-key check: config JSON is untyped, and `in` would accept inherited keys like "constructor". */
function isBackgroundMode(mode: string): mode is keyof typeof IOS_BACKGROUND_MODES {
  return Object.prototype.hasOwnProperty.call(IOS_BACKGROUND_MODES, mode);
}

const DEFAULT_BLUETOOTH_ALWAYS_PERMISSION = 'Allow $(PRODUCT_NAME) to connect to bluetooth devices';

type AndroidManifest = AndroidConfig.Manifest.AndroidManifest;
type InfoPlist = IOSConfig.InfoPlist;

/** A `<uses-permission>` entry with the attributes this plugin sets (the config-plugins type declares only the name). */
type UsesPermission = {
  $: {
    'android:name': string;
    'android:maxSdkVersion'?: string;
    'android:usesPermissionFlags'?: string;
  };
};

/**
 * The manifest's `<uses-permission>` entry for `name`, added without
 * attributes when absent. `added` tells the caller whether the entry is its
 * own to shape (see the rule at the top of this file).
 */
function declarePermission(manifest: AndroidManifest, name: string): { entry: UsesPermission; added: boolean } {
  if (!manifest.manifest['uses-permission']) {
    manifest.manifest['uses-permission'] = [];
  }
  const entries = manifest.manifest['uses-permission'] as UsesPermission[];
  const existing = entries.find((e) => e.$?.['android:name'] === name);
  if (existing) {
    return { entry: existing, added: false };
  }
  const entry: UsesPermission = { $: { 'android:name': name } };
  entries.push(entry);
  return { entry, added: true };
}

/**
 * Removes the neverForLocation flag from `entry`. `android:usesPermissionFlags`
 * is a `|`-separated list, so any other flag in it stays; the attribute goes
 * when nothing is left.
 */
function removeNeverForLocation(entry: UsesPermission): void {
  const flags = entry.$['android:usesPermissionFlags'];
  if (flags === undefined) return;
  const kept = flags
    .split('|')
    .map((flag) => flag.trim())
    .filter((flag) => flag !== '' && flag !== NEVER_FOR_LOCATION);
  if (kept.length === 0) {
    delete entry.$['android:usesPermissionFlags'];
  } else {
    entry.$['android:usesPermissionFlags'] = kept.join('|');
  }
}

/**
 * Declares the bluetooth_le feature with `android:required` = `required`,
 * updating an existing entry rather than only adding a missing one: an entry
 * left by an earlier prebuild or another plugin would otherwise keep a value
 * the config no longer asks for.
 */
function setBleFeatureRequired(manifest: AndroidManifest, required: boolean): void {
  if (!manifest.manifest['uses-feature']) {
    manifest.manifest['uses-feature'] = [];
  }
  const features = manifest.manifest['uses-feature'];
  const value = required ? 'true' : 'false';
  const existing = features.filter((f) => f.$?.['android:name'] === BLE_FEATURE);
  if (existing.length === 0) {
    features.push({ $: { 'android:name': BLE_FEATURE, 'android:required': value } });
  }
  for (const feature of existing) {
    feature.$['android:required'] = value;
  }
}

/**
 * The Android manifest changes for `props`, applied to `manifest` in place.
 * Pure (no Expo mod machinery), so the rules can be tested directly.
 */
export function applyAndroidManifest(manifest: AndroidManifest, props: BleNitroPluginProps): void {
  const {
    isBackgroundEnabled = false,
    neverForLocation = false,
    androidAdvertisingEnabled = false,
    androidBleRequired = false,
  } = props;

  // Legacy Bluetooth permissions, capped at API 30 even when declared
  // elsewhere: the Android Bluetooth permissions guide's compatibility step
  // for apps targeting Android 12+ ("For your legacy Bluetooth-related
  // permission declarations, set android:maxSdkVersion to 30") so 12+
  // grants only what the new permissions say.
  for (const name of LEGACY_BLUETOOTH_PERMISSIONS) {
    declarePermission(manifest, name).entry.$['android:maxSdkVersion'] = LEGACY_MAX_SDK;
  }

  // Android 12+ runtime permissions (the "Nearby devices" prompt) for
  // scanning and for connecting.
  const scan = declarePermission(manifest, BLUETOOTH_SCAN).entry;
  declarePermission(manifest, BLUETOOTH_CONNECT);
  if (neverForLocation) {
    scan.$['android:usesPermissionFlags'] = NEVER_FOR_LOCATION;
  } else {
    // The flag is this option's: without it the app may derive location from
    // scans, and asserting the opposite would make Android filter results
    // the app relies on. A flag an earlier prebuild set is removed.
    removeNeverForLocation(scan);
  }

  for (const name of SCAN_LOCATION_PERMISSIONS) {
    const { entry, added } = declarePermission(manifest, name);
    if (!neverForLocation) {
      // Scan results need location on every API level here: widen.
      delete entry.$['android:maxSdkVersion'];
    } else if (added) {
      // Needed only up to Android 11; a declaration made elsewhere is kept.
      entry.$['android:maxSdkVersion'] = LEGACY_MAX_SDK;
    }
  }

  if (isBackgroundEnabled) {
    const { entry, added } = declarePermission(manifest, ACCESS_BACKGROUND_LOCATION);
    if (added) {
      entry.$['android:maxSdkVersion'] = LEGACY_MAX_SDK;
    }
  }

  if (androidAdvertisingEnabled) {
    declarePermission(manifest, BLUETOOTH_ADVERTISE);
  }

  setBleFeatureRequired(manifest, androidBleRequired);
}

/**
 * The Info.plist changes for `props`, applied to `plist` in place. `modes`
 * values other than the supported ones are skipped (withBleNitroIOS warns
 * about them).
 */
export function applyInfoPlist(plist: InfoPlist, props: BleNitroPluginProps): void {
  const { modes = [], bluetoothAlwaysPermission, iOSLazyInit = false } = props;

  if (bluetoothAlwaysPermission !== false) {
    // An explicit message wins; without one, a message the app already set
    // (e.g. through ios.infoPlist) is kept instead of being replaced by the
    // default.
    const current = plist.NSBluetoothAlwaysUsageDescription;
    plist.NSBluetoothAlwaysUsageDescription =
      bluetoothAlwaysPermission ?? (typeof current === 'string' ? current : DEFAULT_BLUETOOTH_ALWAYS_PERMISSION);
  }

  // The key is this option's: the library reads it and nothing else sets it.
  if (iOSLazyInit) {
    plist.BLENitroLazyInit = true;
  } else {
    delete plist.BLENitroLazyInit;
  }

  const backgroundModes = modes.filter(isBackgroundMode).map((mode) => IOS_BACKGROUND_MODES[mode]);
  if (backgroundModes.length > 0) {
    // Set: each mode once, also when `modes` repeats one; existing order kept.
    plist.UIBackgroundModes = [...new Set([...(plist.UIBackgroundModes ?? []), ...backgroundModes])];
  }
}

export const withBleNitroAndroid: ConfigPlugin<BleNitroPluginProps> = (config, props = {}) =>
  withAndroidManifest(config, (config) => {
    applyAndroidManifest(config.modResults, props);
    return config;
  });

export const withBleNitroIOS: ConfigPlugin<BleNitroPluginProps> = (config, props = {}) => {
  // Validated here rather than in withBleNitro so the exported iOS plugin
  // applied on its own validates too. An unknown mode is skipped, not
  // written as an invalid `bluetooth-<value>` background mode.
  const unsupported = (props.modes ?? []).filter((mode) => !isBackgroundMode(mode));
  if (unsupported.length > 0) {
    WarningAggregator.addWarningForPlatform(
      'ios',
      PLUGIN_NAME,
      `Ignoring unsupported background mode(s) ${unsupported.map((m) => JSON.stringify(m)).join(', ')}. ` +
        'Only "central" and "peripheral" are supported.'
    );
  }

  return withInfoPlist(config, (config) => {
    applyInfoPlist(config.modResults, props);
    return config;
  });
};

const withBleNitro: ConfigPlugin<BleNitroPluginProps> = (config, props = {}) => {
  config = withBleNitroAndroid(config, props);
  config = withBleNitroIOS(config, props);
  return config;
};

export default withBleNitro;
