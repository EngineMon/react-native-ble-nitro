import Foundation

/**
 * Logs a diagnostic of the BLE core: something the core handled by itself (a stale
 * result it dropped) that is worth seeing when a device misbehaves, but that no
 * caller can act on.
 *
 * NSLog because it is the one logging API Foundation offers on every platform the
 * core builds for: on iOS it goes to the unified log (Console.app, Xcode), on Linux,
 * where the core's unit tests run, to stderr. Thread-safe.
 */
func bleLog(_ message: String) {
    NSLog("[BleNitro] %@", message)
}

/**
 * Logs a misuse the core tolerates (a second completion of a one-shot callback, a
 * second settling of a subscription) with the call stack that made it: it is a bug
 * in the calling code, and the stack shows where.
 */
func bleLogWithCallStack(_ message: String) {
    bleLog(message + "\n" + Thread.callStackSymbols.joined(separator: "\n"))
}
