// The app's launch hook for state restoration (CentralHost.swift): makes the
// process's central manager with the restore identifier in Info.plist
// (BLENitroRestoreIdentifier), so iOS can hand a relaunched app its restored
// peripherals before React Native starts. Call it in
// application:didFinishLaunchingWithOptions:, at every launch. Every
// BleNitroManager created with that restoreIdentifier then runs on this
// central. Does nothing without Bluetooth permission (it never asks for it);
// a later call does nothing; any thread. Without the Info.plist key it makes
// nothing, which debug builds stop on (an assertion) and release builds log.
//
// This pod's one public header that isn't nitrogen's (BleNitro.podspec):
// plain C, as the app target can't include the pod's C++ headers. The
// function lives in BleNitroLaunch.mm.
#pragma once

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void BleNitroDidFinishLaunching(void);
