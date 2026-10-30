import Foundation
import NitroModules

/**
 * iOS Factory implementation for BLE Nitro Manager
 * Creates BleNitroBleManager instances with optional state restoration configuration.
 * A manager with the restore identifier the app made its launch central with adopts
 * that central (BleNitroBleManager.init, SharedCentral).
 */
public class BleNitroBleManagerFactory: HybridNativeBleNitroFactorySpec_base, HybridNativeBleNitroFactorySpec_protocol {

    public func create(
        nativeRestoreStateIdentifier: String?,
        restoreStateCallback: (([BLEDevice]) -> Void)?
    ) throws -> any HybridNativeBleNitroSpec {
        return BleNitroBleManager(
            restoreStateIdentifier: nativeRestoreStateIdentifier,
            restoreStateCallback: restoreStateCallback
        )
    }
}
