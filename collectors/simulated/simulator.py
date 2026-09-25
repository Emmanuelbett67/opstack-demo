"""Simulated targets for the demo.

Real integrations need a real database or a real switch to point at. This
stands in for them so the stack can be run anywhere, and so the dashboards
and alerts have something worth showing within a few minutes of starting.

Every metric is prefixed sim_ so nobody mistakes it for a real exporter's
output. The faults run on a fixed clock rather than at random, which makes
the demo repeatable: each profile's cycle is described next to its code.

Standard library only; there is nothing to install.
"""

import argparse
import math
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

START = time.time()


def phase(period_s: float) -> float:
    """Seconds into the current cycle of the given length."""
    return (time.time() - START) % period_s


def wave(period_s: float) -> float:
    """A sine between -1 and 1 over the given period."""
    return math.sin(2 * math.pi * (time.time() - START) / period_s)


class Profile:
    """Keeps counters monotonic by integrating rates between scrapes."""

    def __init__(self):
        self.counters: dict[tuple, float] = {}
        self.last = time.time()
        self.lock = Lock()

    def advance(self, key: tuple, rate_per_s: float, dt: float) -> float:
        self.counters[key] = self.counters.get(key, 0.0) + max(rate_per_s, 0.0) * dt
        return self.counters[key]

    def render(self) -> str:
        with self.lock:
            now = time.time()
            dt, self.last = now - self.last, now
            return "\n".join(self.lines(dt)) + "\n"

    def lines(self, dt: float) -> list[str]:
        raise NotImplementedError


def metric(name: str, value: float, **labels: str) -> str:
    if labels:
        body = ",".join(f'{k}="{v}"' for k, v in labels.items())
        return f"{name}{{{body}}} {value:.6g}"
    return f"{name} {value:.6g}"


class Database(Profile):
    """A relational database.

    Cycle: sessions follow a ten minute wave around 90 of 200, and for four
    minutes in every twenty they surge past 85% of the limit. The USERS
    tablespace sits above 90% full throughout, so its alert is always there
    to find.
    """

    SESSIONS_MAX = 200
    TABLESPACES = {  # name: (size in GiB, fraction used, drift per hour)
        "SYSTEM": (8, 0.71, 0.0),
        "DATA": (500, 0.64, 0.002),
        "USERS": (50, 0.92, 0.001),
        "TEMP": (32, 0.20, 0.0),
    }

    def lines(self, dt: float) -> list[str]:
        surge = phase(1200) < 240
        sessions = 90 + 40 * wave(600) + random.uniform(-6, 6)
        if surge:
            sessions = 178 + random.uniform(-5, 8)
        sessions = min(max(sessions, 5), self.SESSIONS_MAX)

        tps = 220 + 120 * wave(600) + random.uniform(-15, 15)
        hours = (time.time() - START) / 3600

        out = [
            "# TYPE sim_db_up gauge",
            metric("sim_db_up", 1),
            "# TYPE sim_db_sessions_active gauge",
            metric("sim_db_sessions_active", round(sessions)),
            "# TYPE sim_db_sessions_max gauge",
            metric("sim_db_sessions_max", self.SESSIONS_MAX),
            "# TYPE sim_db_transactions_total counter",
            metric("sim_db_transactions_total", self.advance(("tx",), tps, dt)),
            "# TYPE sim_db_tablespace_size_bytes gauge",
            "# TYPE sim_db_tablespace_used_bytes gauge",
        ]
        for name, (gib, used, drift) in self.TABLESPACES.items():
            size = gib * 2**30
            frac = min(used + drift * hours + (0.1 * (wave(300) + 1) if name == "TEMP" else 0), 0.99)
            out.append(metric("sim_db_tablespace_size_bytes", size, tablespace=name))
            out.append(metric("sim_db_tablespace_used_bytes", size * frac, tablespace=name))

        out.append("# TYPE sim_db_wait_seconds_total counter")
        for wait_class, base in {"User I/O": 0.8, "Concurrency": 0.15, "Commit": 0.3, "Network": 0.05}.items():
            rate = base * (3 if surge and wait_class == "Concurrency" else 1) * (1 + 0.3 * wave(600))
            total = self.advance(("wait", wait_class), rate, dt)
            out.append(metric("sim_db_wait_seconds_total", total, wait_class=wait_class))
        return out


class Switch(Profile):
    """A core network switch.

    Cycle: Gi1/0/5 drops for three minutes in every fifteen. Gi1/0/3 logs a
    burst of input errors for five minutes in every twenty. Gi1/0/8 is
    administratively disabled, which is not a fault and must not alert.
    """

    PORTS = {  # name: (description, baseline Mbit/s)
        "Gi1/0/1": ("uplink-core-a", 620),
        "Gi1/0/2": ("uplink-core-b", 540),
        "Gi1/0/3": ("server-rack-1", 310),
        "Gi1/0/4": ("server-rack-2", 280),
        "Gi1/0/5": ("branch-link", 90),
        "Gi1/0/6": ("wifi-controller", 140),
        "Gi1/0/7": ("printers", 12),
        "Gi1/0/8": ("spare", 0),
    }

    def lines(self, dt: float) -> list[str]:
        out = [
            "# TYPE sim_device_uptime_seconds gauge",
            metric("sim_device_uptime_seconds", 86400 * 41 + time.time() - START),
            "# TYPE sim_device_temperature_celsius gauge",
            metric("sim_device_temperature_celsius", 42 + 3 * wave(900) + random.uniform(-0.5, 0.5)),
            "# TYPE sim_if_admin_status gauge",
            "# TYPE sim_if_oper_status gauge",
            "# TYPE sim_if_in_octets_total counter",
            "# TYPE sim_if_out_octets_total counter",
            "# TYPE sim_if_in_errors_total counter",
        ]
        for name, (desc, mbps) in self.PORTS.items():
            admin_up = name != "Gi1/0/8"
            oper_up = admin_up and not (name == "Gi1/0/5" and phase(900) < 180)
            load = mbps * (1 + 0.35 * wave(600)) * random.uniform(0.9, 1.1) if oper_up else 0
            errors = 6.0 if name == "Gi1/0/3" and phase(1200) < 300 else 0.01
            labels = {"ifName": name, "ifAlias": desc}
            out += [
                metric("sim_if_admin_status", 1 if admin_up else 2, **labels),
                metric("sim_if_oper_status", 1 if oper_up else 2, **labels),
                metric("sim_if_in_octets_total", self.advance((name, "in"), load * 125_000, dt), **labels),
                metric("sim_if_out_octets_total", self.advance((name, "out"), load * 0.8 * 125_000, dt), **labels),
                metric("sim_if_in_errors_total", self.advance((name, "err"), errors if oper_up else 0, dt), **labels),
            ]
        return out


PROFILES = {"database": Database, "switch": Switch}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--port", type=int, default=9100)
    args = parser.parse_args()

    profile = PROFILES[args.profile]()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/metrics":
                self.send_error(404)
                return
            body = profile.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    print(f"{args.profile} simulator on :{args.port}/metrics", flush=True)
    ThreadingHTTPServer(("", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
