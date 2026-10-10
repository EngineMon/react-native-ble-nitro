package com.margelo.nitro.co.zyke.ble

/** One GATT procedure waiting in, or running at the head of, a [GattOperationQueue]. */
internal interface GattOperation {
    /** What the operation does, for error messages, e.g. "Characteristic read on AA:BB:CC:DD:EE:FF". */
    val description: String

    /**
     * Issues the operation to the OS. Returns null when the OS accepted it (the
     * operation then waits for [GattOperationQueue.complete] or its timeout), or
     * the error to fail it with.
     */
    fun start(): BleError?

    /** Reports the operation's failure to its caller. Called at most once, and never after it completed. */
    fun fail(error: BleError)
}

/** Runs delayed tasks on the queue's thread: a Handler in the app, a fake clock in tests. */
internal interface OperationTimer {
    fun schedule(task: Runnable, delayMs: Long)
    fun cancel(task: Runnable)
}

/**
 * The GATT operations of one device, run one at a time in FIFO order.
 *
 * Requirements:
 * - Android's BluetoothGatt allows one outstanding procedure per connection (it
 *   refuses a second one while the first awaits its callback), so exactly one
 *   operation is in flight and the others wait in enqueue order.
 * - An operation completes only through the GATT callback that answers it
 *   ([complete]). That includes a write without response, which completes on
 *   onCharacteristicWrite: the stack's flow control, as in RxAndroidBle.
 * - Every operation has a timeout. When its callback doesn't come within
 *   [timeoutMs], it fails with OperationTimedOut and the next one starts; a late
 *   callback for it is then ignored ([complete] returns false).
 * - [failAll] fails the running and every waiting operation (link lost, manager
 *   destroyed).
 * - Results are reported in operation order: an operation's result is delivered
 *   before the next operation starts, so a start failure of the next one can't
 *   overtake it.
 *
 * Not thread-safe: all methods run on the manager's handler thread.
 */
internal class GattOperationQueue(private val timer: OperationTimer, private val timeoutMs: Long) {
    private val waiting = ArrayDeque<GattOperation>()
    private var running: GattOperation? = null
    private val timeout = Runnable { onTimeout() }

    /** The operation awaiting its GATT callback, if any. */
    val current: GattOperation?
        get() = running

    fun enqueue(operation: GattOperation) {
        waiting.addLast(operation)
        if (running == null) startNext()
    }

    /**
     * Completes [operation] if it is the one in flight: [deliver] reports its
     * result, then the next operation starts. Returns false, without calling
     * [deliver], when [operation] is not in flight (it timed out or was failed).
     */
    fun complete(operation: GattOperation, deliver: () -> Unit): Boolean {
        if (running !== operation) return false
        timer.cancel(timeout)
        running = null
        deliver()
        if (running == null) startNext()
        return true
    }

    /** Fails the running and every waiting operation with [error], in queue order. */
    fun failAll(error: BleError) {
        timer.cancel(timeout)
        val failed = listOfNotNull(running) + waiting
        running = null
        waiting.clear()
        failed.forEach { it.fail(error) }
    }

    private fun startNext() {
        while (running == null) {
            val operation = waiting.removeFirstOrNull() ?: return
            running = operation
            timer.schedule(timeout, timeoutMs)
            val error = operation.start() ?: return
            timer.cancel(timeout)
            running = null
            operation.fail(error)
        }
    }

    private fun onTimeout() {
        val operation = running ?: return
        running = null
        operation.fail(bleError(BleErrorCode.OPERATIONTIMEDOUT, "${operation.description} timed out after $timeoutMs ms"))
        if (running == null) startNext()
    }
}
