package com.margelo.nitro.co.zyke.ble

import java.util.logging.Level
import java.util.logging.Logger

/*
 * The pure core's log: java.util.logging under the "BleNitro" name. Android's
 * runtime installs a java.util.logging handler that forwards to logcat (the
 * tag is the logger name, so these lines sit next to the "BleNitro" lines of
 * the platform code), and on the plain JVM the tests capture it with a
 * Handler. This keeps the core free of android.* imports without a logging
 * hook that the platform code could forget to install.
 *
 * Log only preformatted messages: Android's handler prints the raw message,
 * without java.util.logging parameter substitution.
 */

internal val coreLog: Logger = Logger.getLogger("BleNitro")

/** Logs an event worth seeing in a bug report that needs no action (e.g. a result that arrived too late to matter). */
internal fun bleLog(message: String) = coreLog.log(Level.INFO, message)

/**
 * Logs tolerated misuse (e.g. a second completion of a one-shot callback),
 * with the stack trace of the call that did it, so the caller can be found.
 */
internal fun bleLogWithCallStack(message: String) = coreLog.log(Level.WARNING, message, Throwable("call stack"))

/** Logs [thrown], caught where letting it propagate would break an invariant of the caller. */
internal fun bleLogThrown(message: String, thrown: Throwable) = coreLog.log(Level.WARNING, message, thrown)
