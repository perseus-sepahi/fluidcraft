import Foundation

/// The `curlew_post` Python module written next to every post-processing script.
public enum PostScriptModule {
    public static let source = #"""
"""curlew_post: Curlew's Python interface to an OpenFOAM solution.

    import curlew_post as cp
    case = cp.load()                     # the exported time of the case
    U = case["U"]                        # (n_cells, 3) NumPy array; scalars are (n_cells,)
    inlet = case.patches["inlet"]
    cp.report("inlet flow", inlet.flux("U"), "m3/s")   # shown in Curlew
    cp.savefig("my_plot")                # a Matplotlib figure, shown in Curlew
    case.write_field("myField", values)  # a new field in the time directory

Everything is plain NumPy: cells (centres, volumes), patch faces (centres, area vectors,
adjacent cells) and every volume field of the time directory, including fields written by
OpenFOAM function objects. Function-object output under postProcessing/ is read by
case.function_object(name).
"""
import json
import math
import os

import numpy as np

__all__ = ["load", "report", "savefig", "output_dir", "Case", "Patch"]

_DATA = os.environ.get("CURLEW_POST_DATA", "")
output_dir = os.environ.get("CURLEW_POST_OUT", os.getcwd())


def report(name, value, unit=""):
    """Send a named value back to Curlew (shown in the script's results)."""
    v = float(np.asarray(value).item() if np.ndim(value) == 0 else np.asarray(value).ravel()[0])
    print("CURLEW_REPORT " + json.dumps({"name": str(name), "value": v, "unit": str(unit)}), flush=True)
    return v


def savefig(name="figure", fig=None, dpi=150):
    """Save a Matplotlib figure (the current one by default) where Curlew shows it."""
    import matplotlib
    import matplotlib.pyplot as plt
    fig = fig or plt.gcf()
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in str(name)) or "figure"
    path = os.path.join(output_dir, safe + ".png")
    fig.savefig(path, dpi=dpi, bbox_inches="tight")
    plt.close(fig)
    print("CURLEW_FIGURE " + json.dumps({"path": path}), flush=True)
    return path


def _values(case, f, patch=None):
    if isinstance(f, str):
        return patch.field(f) if patch is not None else case.field(f)
    return np.asarray(f, dtype=float)


class Patch:
    """One boundary patch: face centres, area vectors and the field values on its faces."""

    def __init__(self, case, info):
        self._case = case
        self.name = info["name"]
        self.type = info["type"]
        self.n_faces = int(info["nFaces"])
        i = info["index"]
        d = case._dir
        self.centres = np.load(os.path.join(d, f"geom/p{i}_Cf.npy"))
        self.area_vectors = np.load(os.path.join(d, f"geom/p{i}_Sf.npy"))
        self.cells = np.load(os.path.join(d, f"geom/p{i}_cells.npy")).astype(np.int64)
        self.areas = np.linalg.norm(self.area_vectors, axis=1) if self.n_faces else np.zeros(0)
        self.area = float(self.areas.sum())

    @property
    def normal(self):
        """Mean outward unit normal."""
        s = self.area_vectors.sum(axis=0)
        n = np.linalg.norm(s)
        return s / n if n > 0 else s

    def field(self, name):
        """Values of a field on the faces (the adjacent cell values where OpenFOAM wrote none)."""
        info = self._case._fields.get(name)
        if info is None:
            if name in self._case._cache:          # written by this script
                return self._case._cache[name][self.cells]
            raise KeyError(f"no field {name!r}; fields: {', '.join(self._case.fields)}")
        return np.load(os.path.join(self._case._dir, info["patches"][self.name]))

    __getitem__ = field

    def average(self, f):
        """Area-weighted average of a field (name or face array)."""
        v = _values(self._case, f, self)
        if self.area == 0:
            return float("nan")
        w = self.areas / self.area
        return float(np.dot(w, v)) if v.ndim == 1 else np.tensordot(w, v, axes=1)

    def integrate(self, f):
        """Surface integral of a field (name or face array)."""
        v = _values(self._case, f, self)
        return float(np.dot(self.areas, v)) if v.ndim == 1 else np.tensordot(self.areas, v, axes=1)

    def flux(self, f="U"):
        """Σ f·Sf of a vector field (outward positive): the volume flow for U."""
        v = _values(self._case, f, self)
        return float(np.sum(v * self.area_vectors))

    def maximum(self, f):
        return float(np.max(_values(self._case, f, self)))

    def minimum(self, f):
        return float(np.min(_values(self._case, f, self)))

    def __repr__(self):
        return f"Patch({self.name!r}, {self.type}, {self.n_faces} faces, area {self.area:.4g} m²)"


class Case:
    """An OpenFOAM time directory exported by Curlew."""

    def __init__(self, data_dir):
        self._dir = data_dir
        with open(os.path.join(data_dir, "manifest.json")) as fh:
            self.info = json.load(fh)
        self.path = self.info["case"]
        self.time = self.info["time"]
        self.times = self.info["times"]
        self.n_cells = int(self.info["nCells"])
        self.centres = np.load(os.path.join(data_dir, self.info["cells"]["centres"]))
        self.volumes = np.load(os.path.join(data_dir, self.info["cells"]["volumes"]))
        self._fields = self.info["fields"]
        self._cache = {}
        self.patches = {p["name"]: Patch(self, p) for p in self.info["patches"]}
        #: True when p is kinematic (p/ρ, incompressible solvers); False for absolute pressure.
        self.kinematic = bool(self.info.get("kinematicPressure", True))
        #: fluid density from the Curlew setup (None for cases not written by Curlew)
        self.density = self.info.get("density")
        self.operating_pressure = self.info.get("operatingPressure", 0.0)

    @property
    def fields(self):
        return sorted(self._fields)

    def __contains__(self, name):
        return name in self._fields

    def field(self, name):
        """Cell values of a field: (n_cells,) for scalars, (n_cells, 3) vectors, (n_cells, 6|9) tensors."""
        if name not in self._cache:
            info = self._fields.get(name)
            if info is None:
                raise KeyError(f"no field {name!r}; fields: {', '.join(self.fields)}")
            self._cache[name] = np.load(os.path.join(self._dir, info["file"]))
        return self._cache[name]

    __getitem__ = field

    def pressure_pa(self, patch=None):
        """Static gauge pressure in Pa (kinematic p × ρ; absolute p − operating pressure)."""
        p = patch.field("p") if patch is not None else self.field("p")
        if self.kinematic:
            return p * (self.density if self.density else 1.0)
        return p - (self.operating_pressure or 0.0)

    def volume_integral(self, f, mask=None):
        v = _values(self, f)
        w = self.volumes if mask is None else self.volumes * np.asarray(mask, dtype=float)
        return float(np.dot(w, v)) if v.ndim == 1 else np.tensordot(w, v, axes=1)

    def volume_average(self, f, mask=None):
        w = self.volumes if mask is None else self.volumes * np.asarray(mask, dtype=float)
        total = w.sum()
        return self.volume_integral(f, mask) / total if total > 0 else float("nan")

    def nearest_cells(self, points, k=1):
        """Indices of the k cells whose centres are nearest to each point ((n,) or (n, k))."""
        pts = np.atleast_2d(np.asarray(points, dtype=float))
        try:
            from scipy.spatial import cKDTree
            if getattr(self, "_tree", None) is None:
                self._tree = cKDTree(self.centres)
            _, idx = self._tree.query(pts, k=k)
            return np.asarray(idx, dtype=np.int64)
        except ImportError:
            pass
        c = self.centres
        cc = (c * c).sum(axis=1)
        out = np.empty((len(pts), k), dtype=np.int64)
        step = max(1, int(5e6 // max(len(c), 1)))      # bounded memory: step × n_cells distances
        for i in range(0, len(pts), step):
            p = pts[i:i + step]
            d = cc[None, :] - 2.0 * p @ c.T
            part = np.argpartition(d, kth=min(k, len(c)) - 1, axis=1)[:, :k] if k < len(c) else np.tile(np.arange(len(c)), (len(p), 1))
            order = np.take_along_axis(d, part, axis=1).argsort(axis=1)
            out[i:i + step] = np.take_along_axis(part, order, axis=1)
        return out[:, 0] if k == 1 else out

    def probe(self, points, f, method="nearest"):
        """Field values at points: the nearest cell centre, or method="interpolate" for an
        inverse-distance blend of the nearest cells (smooth along lines)."""
        v = _values(self, f)
        pts = np.atleast_2d(np.asarray(points, dtype=float))
        if method == "nearest":
            return v[self.nearest_cells(pts)]
        k = 4 if np.ptp(self.centres[:, 2]) < 1e-12 * max(np.ptp(self.centres), 1e-300) else 8
        k = min(k, self.n_cells)
        idx = self.nearest_cells(pts, k=k).reshape(len(pts), k)
        d = np.linalg.norm(self.centres[idx] - pts[:, None, :], axis=2)
        w = 1.0 / np.maximum(d, 1e-12 * np.ptp(self.centres)) ** 2
        exact = d[:, 0] < 1e-12 * max(np.ptp(self.centres), 1e-300)
        w[exact] = 0.0
        w[exact, 0] = 1.0
        w /= w.sum(axis=1, keepdims=True)
        vals = v[idx]
        return (w * vals).sum(axis=1) if v.ndim == 1 else np.einsum("nk,nkc->nc", w, vals)

    def line(self, start, end, n=100, field="U", method="interpolate"):
        """Sample a field at n points from start to end: returns (distance, values)."""
        a, b = np.asarray(start, dtype=float), np.asarray(end, dtype=float)
        t = np.linspace(0.0, 1.0, int(n))
        pts = a[None, :] + t[:, None] * (b - a)[None, :]
        return t * np.linalg.norm(b - a), self.probe(pts, field, method=method)

    def function_objects(self):
        """Names of the directories under postProcessing/."""
        d = os.path.join(self.path, "postProcessing")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def function_object(self, name, file=None):
        """Columns of a function object's .dat/.csv output, all start times joined: {column: array}."""
        base = os.path.join(self.path, "postProcessing", name)
        if not os.path.isdir(base):
            return {}
        def as_float(t):
            try:
                return float(t)
            except ValueError:
                return math.nan
        starts = sorted((s for s in os.listdir(base) if os.path.isdir(os.path.join(base, s))), key=as_float)
        cols, rows = None, []
        for s in starts:
            files = sorted(f for f in os.listdir(os.path.join(base, s)) if f.endswith((".dat", ".csv", ".xy")))
            if file:
                files = [f for f in files if f == file or f.startswith(file)]
            if not files:
                continue
            with open(os.path.join(base, s, files[0])) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("#"):
                        words = line.lstrip("#").replace(",", " ").split()
                        if words and words[0] in ("Time", "time", "Iteration", "x", "distance"):
                            cols = words
                        continue
                    parts = line.replace(",", " ").replace("(", " ").replace(")", " ").split()
                    rows.append([as_float(p) for p in parts])
        if not rows:
            return {}
        width = max(len(r) for r in rows)
        arr = np.full((len(rows), width), np.nan)
        for i, r in enumerate(rows):
            arr[i, :len(r)] = r
        names = cols if cols and len(cols) == width else (cols or []) + [f"c{i}" for i in range(len(cols or []), width)]
        return {names[i]: arr[:, i] for i in range(width)}

    def residuals(self):
        return self.function_object("solverResiduals") or self.function_object("solverInfo")

    def write_field(self, name, values, dimensions="[0 0 0 0 0 0 0]"):
        """Write a cell field (n_cells,) or (n_cells, 3) into the time directory as an OpenFOAM
        volScalarField / volVectorField that ParaView, OpenFOAM utilities and Curlew can read."""
        if not name.replace("_", "").replace(".", "").isalnum() or not name[0].isalpha():
            raise ValueError(f"{name!r} is not an OpenFOAM field name")
        v = np.asarray(values, dtype=float)
        if v.shape[0] != self.n_cells or v.ndim > 2 or (v.ndim == 2 and v.shape[1] != 3):
            raise ValueError(f"expected ({self.n_cells},) or ({self.n_cells}, 3), got {v.shape}")
        vector = v.ndim == 2
        cls, kind = ("volVectorField", "vector") if vector else ("volScalarField", "scalar")
        fmt = (lambda x: "(%.10g %.10g %.10g)" % tuple(x)) if vector else (lambda x: "%.10g" % x)
        def lst(a):
            return f"nonuniform List<{kind}> {len(a)}\n(\n" + "\n".join(fmt(x) for x in a) + "\n)"
        constraint = {"empty", "symmetry", "symmetryPlane", "wedge", "cyclic", "cyclicAMI", "processor", "cyclicSlip"}
        out = ["FoamFile\n{\n    version     2.0;\n    format      ascii;\n"
               f"    class       {cls};\n    location    \"{self.time}\";\n    object      {name};\n}}\n",
               f"dimensions      {dimensions};\n\ninternalField   {lst(v)};\n\nboundaryField\n{{\n"]
        for p in self.patches.values():
            if p.type in constraint:
                out.append(f"    {p.name}\n    {{\n        type            {p.type};\n    }}\n")
            else:
                vals = v[p.cells] if p.n_faces else v[:0]
                out.append(f"    {p.name}\n    {{\n        type            calculated;\n        value           {lst(vals)};\n    }}\n")
        out.append("}\n")
        path = os.path.join(self.path, str(self.time), name)
        with open(path, "w") as fh:
            fh.write("".join(out))
        self._fields[name] = None
        self._cache[name] = v
        print("CURLEW_FIELD " + json.dumps({"name": name, "path": path}), flush=True)
        return path

    def __repr__(self):
        return f"Case({self.path!r}, time {self.time}, {self.n_cells} cells, {len(self._fields)} fields)"


def load(data_dir=None):
    """The solution Curlew exported for this script."""
    d = data_dir or _DATA
    if not d or not os.path.isfile(os.path.join(d, "manifest.json")):
        raise RuntimeError("no exported solution: run this script from Curlew (Post-Processing › Python Scripts) "
                           "or with `curlew post-script`")
    return Case(d)
"""#
}
