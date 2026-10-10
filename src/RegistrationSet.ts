/**
 * One JS callback set registered with the native manager: a characteristic
 * subscription, a state listener or a connection-event listener. An opaque
 * token: whether it is active is a question for the RegistrationSet that
 * opened it, so nothing else can revive or end it.
 */
export class Registration {
  /**
   * A private member makes the type nominal: no other object, e.g. a plain
   * `{}`, can stand in for a Registration. A plain field, not a `declare`d
   * one: React Native's Babel preset, which compiles this source in apps,
   * rejects `declare` class fields.
   */
  private readonly _opaque = true;
}

/**
 * The active registrations of one manager.
 *
 * A registration ends exactly once: on remove(), a failed subscribe, the
 * subscription's end, or destroy() (endAll). From then on its callbacks must
 * get nothing, also not what the native side sent before (a native callback
 * reaches the JS thread later than it was fired), and releasing it must not go
 * to native again. Callbacks therefore check `isActive` on every call, and
 * the one caller whose `end` returned true releases the native registration.
 */
export class RegistrationSet {
  private readonly _active = new Set<Registration>();

  open(): Registration {
    const registration = new Registration();
    this._active.add(registration);
    return registration;
  }

  isActive(registration: Registration): boolean {
    return this._active.has(registration);
  }

  /** Ends the registration. True when it was active: the caller then releases it natively. */
  end(registration: Registration): boolean {
    return this._active.delete(registration);
  }

  /** Ends every registration (destroy(): the native side releases them itself). */
  endAll(): void {
    this._active.clear();
  }
}
