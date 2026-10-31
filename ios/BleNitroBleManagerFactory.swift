import Foundation
import NitroModules

/**
 * iOS Factory implementation for BLE Nitro Manager
 * Creates BleNitroBleManager instances with optional state restoration configuration.
 * Managers with the same restore identifier share the process's central for it, the
 * newest superseding the one before (BleNitroBleManager.init, CentralHost).
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
