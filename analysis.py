"""Example Curlew post-processing script.

    curlew-cli post-script --case ~/CurlewFoam/run1 --script analysis.py
"""
import numpy as np
import matplotlib.pyplot as plt
import curlew_post as cp

case = cp.load()
print(case)
print("patches:", {name: p.type for name, p in case.patches.items()})

U = case["U"]
speed = np.linalg.norm(U, axis=1)
cp.report("max speed", speed.max(), "m/s")
cp.report("volume-mean speed", case.volume_average(speed), "m/s")

# u-velocity along the vertical centreline (the Ghia et al. 1982 benchmark line)
lo, hi = case.centres.min(axis=0), case.centres.max(axis=0)
x, z = 0.5 * (lo[0] + hi[0]), 0.5 * (lo[2] + hi[2])
y, u = case.line([x, lo[1], z], [x, hi[1], z], n=200, field="U")
cp.report("min u on the centreline", u[:, 0].min(), "m/s")

plt.figure(figsize=(4, 5))
plt.plot(u[:, 0], y)
plt.xlabel("u (m/s)")
plt.ylabel("y (m)")
plt.title(f"Vertical centreline, t = {case.time}")
plt.grid(alpha=0.3)
cp.savefig("centreline_u")

case.write_field("speed", speed)     # a new field in the time directory, for ParaView
