# Third-party notices

FluidCraft is distributed under the GNU General Public License, version 3 (see `LICENSE`).
It is written in Swift against Apple's system frameworks and includes no third-party source code
or libraries.

## Programs FluidCraft runs but does not include

FluidCraft starts these programs as separate processes when they are installed on your Mac.
They are not part of the FluidCraft download; each comes with its own licence from its own
authors. Settings › Tools can install them with Homebrew at your request.

| Program | Used for | Licence | Source |
|---|---|---|---|
| OpenFOAM (ESI-OpenCFD release) | solving every case, blockMesh, snappyHexMesh, mesh conversion | GNU GPL v3 | https://www.openfoam.com, https://develop.openfoam.com |
| OpenFOAM for macOS app bundle | the macOS build of OpenFOAM that Settings › Tools installs | GNU GPL v3 | https://github.com/gerlero/openfoam-app |
| Gmsh | unstructured and CAD meshing, STEP/IGES tessellation | GNU GPL v2 or later | https://gmsh.info |
| ParaView (optional) | opening OpenFOAM cases from the Solve menu | BSD 3-Clause | https://www.paraview.org |
| Python, NumPy, PyTorch (optional) | post-processing scripts and physics-informed neural networks | PSF, BSD 3-Clause, BSD-style | https://www.python.org, https://numpy.org, https://pytorch.org |
| Homebrew (optional) | installing the programs above | BSD 2-Clause | https://brew.sh |

## Published data

The validation suite compares results with published benchmark data, cited where it is used:
Ghia, Ghia and Shin (1982), de Vahl Davis (1983), Schäfer and Turek (1996), the Kármán–Schoenherr
and Petukhov correlations, and the exact Sod and oblique-shock solutions.

## Trademarks

OPENFOAM® is a registered trade mark of OpenCFD Limited, producer and distributor of the
OpenFOAM software via www.openfoam.com. FluidCraft is not approved or endorsed by OpenCFD
Limited.

Ansys and Fluent are trademarks of ANSYS, Inc. FluidCraft reads and writes Fluent mesh files and
compares itself with Ansys Fluent in its documentation; it is not affiliated with or endorsed by
ANSYS, Inc.

ParaView is a trademark of Kitware, Inc. Python is a trademark of the Python Software Foundation.
PyTorch is a trademark of The Linux Foundation. Apple, Mac and macOS are trademarks of Apple Inc.
All other names belong to their owners.
