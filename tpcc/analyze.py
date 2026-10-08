#!/usr/bin/env python3
"""Summarise a TPC-C run.

Compares the three modes that separate the two halves of prepared statement
caching:

    off    caching disabled
    part1  worker-side prepared statements, tasks built by normal planning
    both   part1 plus the coordinator fast path

TPC-C mutates its own dataset as it runs, so spread matters as much as the
median: a difference smaller than the run-to-run noise is not a result.
"""

import csv
import statistics
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "summary.csv"

ORDER = ["off", "part1", "both"]

data = {}
iteration_data = {}
with open(path) as f:
    for row in csv.DictReader(f):
        clients_value = int(row["clients"])
        mode = row["mode"]
        iteration = int(row["iter"])
        tps = float(row["tps"])
        key = (clients_value, mode)
        data.setdefault(key, {"tps": [], "lat": [], "nopm": []})
        data[key]["tps"].append(tps)
        data[key]["lat"].append(float(row["lat_avg_ms"]))
        data[key]["nopm"].append(float(row["nopm"]))
        iteration_data.setdefault((clients_value, iteration), {})[mode] = tps


def cv(values):
    """Coefficient of variation, as a percentage."""
    if len(values) < 2 or statistics.mean(values) == 0:
        return 0.0
    return 100 * statistics.stdev(values) / statistics.mean(values)


clients = sorted({k[0] for k in data})
modes = [m for m in ORDER if any(k[1] == m for k in data)]
modes += sorted({k[1] for k in data} - set(ORDER))

print(
    f"{'Clients':>7} {'Mode':>6} {'Med TPS':>10} {'Med NOPM':>10} {'Med Lat':>11} "
    f"{'CV':>7}   runs"
)
print("-" * 88)
for c in clients:
    for m in modes:
        d = data.get((c, m))
        if not d:
            continue
        vals = ", ".join(f"{v:.0f}" for v in sorted(d["tps"]))
        print(
            f"{c:>7} {m:>6} {statistics.median(d['tps']):>10.1f} "
            f"{statistics.median(d['nopm']):>10.0f} "
            f"{statistics.median(d['lat']):>9.2f}ms {cv(d['tps']):>6.1f}%   [{vals}]"
        )
    print()

print("=== TPS drift by iteration ===")
print(f"{'Clients':>7} {'First':>10} {'Last':>10} {'d%':>8}  complete iterations")
print("-" * 62)
for c in clients:
    client_modes = {mode for clients_value, mode in data if clients_value == c}
    complete = []
    for (clients_value, iteration), values in sorted(iteration_data.items()):
        if clients_value == c and set(values) == client_modes:
            complete.append((iteration, statistics.mean(values.values())))

    if len(complete) < 2:
        print(f"{c:>7} {'n/a':>10} {'n/a':>10} {'n/a':>8}  {len(complete)}")
        continue

    first = complete[0][1]
    last = complete[-1][1]
    delta = 100 * (last - first) / first
    print(f"{c:>7} {first:>10.1f} {last:>10.1f} {delta:>+7.1f}%  {len(complete)}")

print()
print("Each point averages all modes from the same iteration, so rotating mode")
print("order does not hide elapsed-time drift. Large negative values indicate")
print("that database growth, maintenance, or infrastructure drift may dominate")
print("the feature comparison. Failed or incomplete iterations are excluded.")
print()

if "off" in modes:
    print("=== vs off (median TPS) ===")
    print(f"{'Clients':>7} {'Mode':>6} {'d%':>8} {'noise':>8}  verdict")
    print("-" * 52)
    for c in clients:
        base = data.get((c, "off"))
        if not base:
            continue
        b = statistics.median(base["tps"])
        for m in modes:
            if m == "off" or (c, m) not in data:
                continue
            v = statistics.median(data[(c, m)]["tps"])
            delta = 100 * (v - b) / b
            noise = max(cv(base["tps"]), cv(data[(c, m)]["tps"]))
            verdict = "inconclusive" if abs(delta) < 2 * noise else "signal"
            print(f"{c:>7} {m:>6} {delta:>+7.1f}% {noise:>7.1f}%  {verdict}")
    print()
    print("A result counts only when the difference exceeds twice the worst")
    print("run-to-run coefficient of variation. Aim for CV under 5%; if it is")
    print("higher the environment, not the feature, is what is being measured.")
    print()
    print("'both' minus 'part1' is what the coordinator fast path is worth;")
    print("'part1' minus 'off' is what worker-side preparation is worth.")
