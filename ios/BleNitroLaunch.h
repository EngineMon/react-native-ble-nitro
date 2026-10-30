// The app's launch hook for state restoration (SharedCentral.swift): makes the
// process's central manager with `restoreIdentifier`, so iOS can hand a
// relaunched app its restored peripherals before React Native starts. Call it
// in application:didFinishLaunchingWithOptions:, on the main thread, at every
// launch, with the restoreIdentifier the JS BleNitroManager is created with:
// that manager then runs on this central instead of making its own. Does
// nothing without Bluetooth permission (it never asks for it), or when called
// again.
//
// This pod's one public header that isn't nitrogen's (BleNitro.podspec):
// plain C, as the app target can't include the pod's C++ headers. The
// function lives in BleNitroLaunch.mm.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void BleNitroDidFinishLaunching(NSString *restoreIdentifier);

NS_ASSUME_NONNULL_END
