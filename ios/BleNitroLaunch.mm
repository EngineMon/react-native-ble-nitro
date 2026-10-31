#import "BleNitroLaunch.h"
// The Swift side (BleNitroLaunch in CentralHost.swift), through the Swift
// header nitrogen's own BleNitroAutolinking.mm includes too.
#import "BleNitro-Swift-Cxx-Umbrella.hpp"

void BleNitroDidFinishLaunching(void) {
  [BleNitroLaunch didFinishLaunching];
}
