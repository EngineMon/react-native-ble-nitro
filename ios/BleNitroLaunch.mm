#import "BleNitroLaunch.h"
// The Swift side (BleNitroLaunch in SharedCentral.swift), through the Swift
// header nitrogen's own BleNitroAutolinking.mm includes too.
#import "BleNitro-Swift-Cxx-Umbrella.hpp"

void BleNitroDidFinishLaunching(NSString *restoreIdentifier) {
  [BleNitroLaunch didFinishLaunchingWithRestoreIdentifier:restoreIdentifier];
}
