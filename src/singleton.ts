import { BleNitroManager } from "./manager";

let _instance: BleNitroManager;

export class BleNitro extends BleNitroManager {
  /**
   * Get a singleton instance of BleNitro, will create one if it does not exist.
   * Singleton implementation does not allow to use state restoration on iOS!
   * Every caller shares it, so don't destroy() it; create your own
   * BleNitroManager if you need to.
   * @returns {BleNitroManager} An instance of BleNitro
   */
  public static instance(): BleNitroManager {
    if (!_instance) {
      _instance = new BleNitroManager();
    }
    return _instance;
  }
}