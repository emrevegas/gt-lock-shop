"""Luci worker heartbeat (last API poll time)."""

import time

last_poll_at: float = 0.0


def touch_poll() -> None:
    global last_poll_at
    last_poll_at = time.time()


def seconds_since_poll() -> float | None:
    if last_poll_at <= 0:
        return None
    return time.time() - last_poll_at
