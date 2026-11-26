FluidCraft 1.0 is the first public release: computational fluid dynamics for the Mac, with OpenFOAM as the solver.

## What's in it

- **Modules**: wind farm (actuator disks), wind-turbine rotor (MRF), air-cooled heat sink and liquid cold plate (conjugate heat transfer), and CAD analysis that meshes and sets up your STEP, IGES or STL model.
- **Setup**: laminar and turbulent flow (k-ε, k-ω SST, Spalart–Allmaras, LES/DES), heat transfer and buoyancy, compressible and supersonic flow, solid, porous and rotating zones, periodic boundaries.
- **Meshing**: blockMesh, Gmsh and snappyHexMesh, prism layers from a y⁺ target, and Fluent, Gmsh and OpenFOAM mesh import through OpenFOAM's own converters.
- **Results**: contours, vectors, pathlines, cut planes, XY plots, reports, ParaView export, Python post-processing scripts.
- **Tutorials and a validation suite** against published benchmarks, physics-informed neural networks, and an optional AI assistant.
- A **Start page**, step status in the sidebar, a live OpenFOAM status, **Settings › Tools** to install OpenFOAM and Gmsh, and a built-in user guide (Help › FluidCraft Guide).

## Install

1. Open `FluidCraft.dmg` and drag FluidCraft to Applications.
2. Open FluidCraft. If OpenFOAM or Gmsh is missing, the Start page says so: **Settings › Tools** installs them with Homebrew (OpenFOAM for macOS is about 1 GB).
3. Try the **Lid-driven cavity** tutorial on the Start page and press ⌘R.

## Requirements

macOS 15 or later on Apple silicon. OpenFOAM (ESI release, v2406 or newer) and Gmsh; ParaView and Python are optional.

## Formerly Curlew

FluidCraft was called Curlew during development. Cases saved as `.curlew` open, and Curlew's settings and AI keys carry over on first launch.

FluidCraft is free and open source under the GNU GPL v3. Signed and notarized by Apple.
