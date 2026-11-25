# Curlew

A native macOS computational fluid dynamics application built around the Fluent-style
workflow (Mesh → Setup → Solution → Results). **OpenFOAM is the default solver**: Curlew writes
the setup as an OpenFOAM case, runs it in an installed OpenFOAM and reads the results back. Its
own unstructured finite-volume pressure-based and density-based solvers remain as a fallback
(used automatically when no OpenFOAM is installed), a Metal graphics window, aggregation AMG with an
optional Metal GPU backend, CAD import (STEP, IGES, BREP, FreeCAD, STL, OBJ, PLY, OFF, 3MF, glTF, AMF, VTK, and native
SolidWorks/CATIA/Parasolid/… files through a converter) meshed with
Gmsh or snappyHexMesh, and a validation suite that reproduces published benchmarks.

© 2026 Perseus Sepahi

## What is in it

**Modules** (the category buttons along the top of the window, each a dropdown, and the Module
selector)

| Category | Module | What you configure |
|---|---|---|
| Wind Energy | Wind Farm | rows × turbines, spacing (in D), rotor diameter, hub height, Ct, Cp, hub-height wind, terrain roughness z₀, domain margins, cells per diameter, turbulence model |
| Wind Energy | Wind-Turbine Rotor | radius, blade count, NACA aerofoil, design angle of attack, hub size, wind speed, tip-speed ratio, blade/far cell sizes, domain, turbulence model |
| Electronics Cooling | Air-Cooled Heat Sink | chip power and size, board size/thickness/material, heat-sink footprint, base, fin count/thickness/height, material, duct height, inlet speed and temperature, cell size |
| Electronics Cooling | Liquid Cold Plate | chip power, plate size, channel count/width/height, floor and lid, manifolds, plate material, coolant, inlet speed and temperature, cell size |
| General CFD & CAD | CAD Import & Analysis | your CAD file or one of nine samples, units, analysis type (external aerodynamics, internal flow, conjugate heat sink), flow direction and speed, fluid, solid, heat load, mesher, resolution, prism layers |
| General CFD & CAD | Tutorials & Validation | the textbook cases and the validation suite |
| General CFD & CAD | Custom Case | mesh generation or import, then the Setup and Solution pages |
| Pre & Post-Processing | Pre-Processing | mapFields from another case, setFields regions (box, sphere, cylinder) with field values, applyBoundaryLayer, full checkMesh |
| Pre & Post-Processing | Post-Processing | derived fields (vorticity, Q, λ₂, enstrophy, Courant, Péclet, Mach, wall shear, y⁺, wall heat flux, stream function, flow type, turbulence fields), line samples into the XY plot, iso-surfaces, streamlines, VTK and EnSight export, run after every solve or on demand |
| AI & Machine Learning | Physics-Informed Neural Network | mode (physics / hybrid / surrogate), layers, neurons, activation, Fourier features, Adam epochs, learning rate and decay, L-BFGS, batch sizes, loss weights, energy, device, seed, Python and PyTorch status with Install / Repair |
| AI & Machine Learning | AI Assistant | provider (Anthropic Claude, OpenAI-compatible, local Ollama), model, endpoint, effort, token limit, case summary on/off |

Each module appears once, in one category. Pre- and post-processing run OpenFOAM's own
utilities: `mapFields`, `setFields`, `applyBoundaryLayer`, `<solver> -postProcess`, `foamToVTK`
and `foamToEnsight`. Curlew writes their dictionaries and runs them as stages, so what you set
is exactly what OpenFOAM does.

Each case-building module makes the mesh and a complete OpenFOAM-ready setup (Build Case), or
builds and runs it (Build and Run); everything it sets stays editable on the Setup, Solution
and OpenFOAM pages. Module choices and parameters are saved with the case.

**Physics-informed neural networks**: the PINN module writes the open case as a training
problem (cell centres as collocation points; boundary faces with their conditions; optional
samples of the current OpenFOAM solution) plus a PyTorch script, and trains it with a Python
interpreter set in Settings › Machine Learning. Steady incompressible Navier–Stokes and
convection–diffusion of temperature are learned in non-dimensional form. Velocity, pressure,
no-slip and slip walls, outlets, fixed temperature, adiabatic, heat-flux and convection walls
all have loss terms. The prediction is loaded back as a solution, so contours, vectors,
pathlines, reports and XY plots work on it. Fluid regions only (no solid zones yet). "Set Up
PyTorch Environment…" creates `~/CurlewFoam/pinn-env` with PyTorch and NumPy when you ask for it. From the command line: `curlew-cli pinn cavity-re100 [--mode hybrid --solve] [--epochs N] [--device cpu|mps]`, or `curlew-cli pinn case.curlew`.

**AI assistant**: questions about the open case go to Claude (`claude-opus-5-5` by default,
Anthropic Messages API with adaptive thinking, selectable effort and server-side refusal
fallback), an OpenAI-compatible endpoint, or a local Ollama model. With "Send case summary" on,
each question carries the setup, boundary and cell-zone conditions, materials, mesh quality,
latest residuals, reports and recent warnings. API keys are kept in the macOS Keychain (or read
from `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`), never in case files.

**Meshing**
- Structured block mesher (2D slabs and 3D, graded segments, rectangular obstacles, box-defined solid/porous cell zones, named patches) and a 2D cylinder O-grid.
- Gmsh workflow (uses `/Applications/Gmsh.app`): channel + cylinder, NACA 4-digit airfoil in a far field with boundary-layer quads, 3D pipe, and **CAD import** for external flow (body subtracted from a box) or internal flow, with inlet/outlet/far-field/wall named selections assigned automatically.
- **CAD formats**: exact B-rep geometry (STEP `.step/.stp`, IGES `.iges/.igs`, OpenCASCADE `.brep`, FreeCAD `.FCStd`, whose visible shapes are extracted from the document and combined) through Gmsh's OpenCASCADE kernel; triangulated surfaces (STL ASCII/binary with one region per `solid`, Wavefront OBJ with groups, PLY ASCII/binary, OFF, 3MF with one region per object, glTF 2.0 `.gltf/.glb` with node transforms and one region per mesh, AMF plain or zipped, VTK legacy polydata) read by Curlew, welded, cleaned and oriented. File units m/mm/cm/in/ft (3MF, AMF and glTF declare their own; large models are flagged as probably millimetres). Triangulated surfaces are split into smooth patches at a feature angle, reparametrized and remeshed by Gmsh; surfaces that must bound a volume are checked for open edges first.
- **SolidWorks and SolidCraft:**
  - SolidWorks: export STEP (AP214/AP242), IGES, STL or 3MF and open it directly. Native `.sldprt` and Parasolid files need a converter.
  - SolidCraft: its `.sc` designs open directly. Curlew runs SolidCraft's own `solidcraft-cli` to write exact STEP, the same bridge Draftwright uses. Its STEP, 3MF, STL and OBJ exports open too, and Rhino `.3dm` files go through SolidCraft when no other converter is set.
  - Units: the length unit a STEP file declares is used automatically. Files from the bare OpenCASCADE writer (Gmsh) are not trusted, because they always say millimetres.
- **Region to simulate** (CAD Import & Analysis, external flow and the conjugate duct):
  - Domain margins in body lengths: upstream, downstream, beside, below, above.
  - A body standing on the ground: the floor is a wall, optionally moving at the free-stream speed (rolling road), and it is left out of the body forces.
  - A refinement box with its own cell size: a Gmsh Box field, or the snappyHexMesh refinement box.
  - 3D CAD meshes are cleaned with Gmsh's Netgen optimiser.
- **Native CAD formats** (SolidWorks `.sldprt/.sldasm`, CATIA `.CATPart/.CATProduct`, Parasolid `.x_t/.x_b`, Creo/NX `.prt/.asm`, Inventor `.ipt/.iam`, Solid Edge `.par/.psm`, Rhino `.3dm`, ACIS `.sat/.sab`, JT, IFC): their kernels are proprietary and no open reader exists, so Curlew runs a converter you configure (Settings › Native CAD formats, `CURLEW_CAD_CONVERTER`, or `--converter`), a command with `{input}` and `{output}` placeholders such as CAD Exchanger's `ExchangerConv -i {input} -e {output}`, and meshes the STEP it writes. The command is run directly without a shell, with the placeholders substituted per argument, so a file name can never act as a command. It is read only from preferences, the environment or the command line, and never from case files. Without a converter, Curlew explains how to export STEP instead.
- **Internal-flow openings** are found from the geometry: planar caps on the body's bounding box are grown across shared edges; caps at the two ends of the flow direction become `inlet`/`outlet` (`inlet2`… when there are several), and smaller caps on the other sides become extra outlets (`outlet_ymax`, `outlet_zmin`…), so elbows, tees and manifolds get every opening named without any setup. A rectangular duct's side walls are not mistaken for openings because they cover the whole face of the box. This works for STEP/IGES (a coarse probe triangulation finds the caps, then the exact CAD faces are selected), triangulated files and snappyHexMesh.
- **snappyHexMesh meshing of CAD** (needs OpenFOAM): background block sized from the body, `surfaceFeatureExtract`, surface and feature refinement levels, a refinement box around the body and its wake, prism layers (relative or absolute first-layer thickness), mesh-quality limits, `locationInMesh` found automatically with an inside/outside ray test, serial or `mpirun` parallel meshing with `reconstructParMesh`, `checkMesh`, then the polyMesh is imported with each STL solid/OBJ group as its own patch. STEP/IGES are tessellated with Gmsh first, at a size tied to the finest surface level.
- **3D prism boundary layers (inflation)** on the Gmsh pipe and CAD meshes: first-layer height, growth rate and number of layers, with a y⁺ calculator that sizes the first layer. The tetrahedral mesh is pushed away from the walls along smoothed normals, the displacement is relaxed into the surrounding cells, and the gap is filled with prism stacks. The layers slide along inlets, outlets and symmetry planes. Where the volume mesh lacks room, a stack is thinned locally; the first-layer height is kept and the growth rate is reduced instead. Every insertion is checked for inverted or folded cells, and the generated meshes pass OpenFOAM `checkMesh`.


  ![Prism layers in the turbulent pipe tutorial](Docs/prism-layers.png)
  *Cross-section of the turbulent pipe tutorial: 14 graded prism layers (first cell at y⁺ ≈ 0.94) under the tetrahedral core, coloured by axial velocity.*
- **CAD Analysis** (Meshing › CAD Analysis, File › Import CAD for Analysis…, `curlew-cli cad-analysis`): choose a CAD file and an analysis type: external aerodynamics (drag, lift), internal flow (pressure drop, flow split) or electronics cooling / heat sink (conjugate). Curlew sizes the enclosure and cells from the model, picks laminar or k-ω SST from the Reynolds number, sizes the first prism layer, meshes the model with Gmsh or snappyHexMesh, and sets up materials, boundary conditions, reference values and reports. For heat sinks, the solid and the surrounding air are meshed together with a conformal interface (OpenCASCADE BooleanFragments), and the heat load enters through the solid's lowest face.
- **CAD samples** (File › CAD Samples, `curlew-cli samples`): eight parametric OpenCASCADE models saved as STEP, so each behaves exactly like a file from a CAD system:
  - a sphere
  - an Ahmed body with a 25° slant
  - a NACA 0012 wing at 4°
  - a 90° pipe elbow
  - a mixing tee
  - a 9-fin plate-fin heat sink
  - a twisted and tapered NACA 4412 wind-turbine blade, lofted through six sections
  - a three-blade rotor
- Importers: Fluent `.msh`/`.cas` (ASCII and binary, 2D and 3D, mixed/polygonal faces, multiple cell zones), Gmsh `.msh` 2.2/4.1 (all linear element types; higher-order reduced to corners), OpenFOAM `polyMesh` (ASCII/binary/gzip).
- Exporters: Fluent ASCII `.msh`, OpenFOAM case (mesh with cell zones, `0/`, `constant/`, `system/`, `Allrun`) for any of the backend applications below, ParaView `.vtu` (polyhedral cells), CSV.
- Mesh check: Fluent-style orthogonal quality, aspect ratio, non-orthogonality, volume statistics; zone renaming/retyping.

**Pressure-based solver** (cell-centred, collocated, face-based polyhedral)
- SIMPLE, SIMPLEC, PISO; Rhie–Chow with under-relaxation and time-step consistency terms.
- Least-squares and Green–Gauss gradients; the pressure force uses a conservative Green–Gauss gradient with skewness-corrected face values, which is exact for linear fields like least squares, but the pressure force on any region equals the pressure integral over its boundary; first/second-order upwind, central, bounded central, QUICK and MUSCL convection with TVD (van Leer) bounding; over-relaxed non-orthogonal correction with automatic limiting.
- Pressure interpolation: Standard (momentum-weighted at porous interfaces), Second Order (limited extrapolation), Body Force Weighted.
- Steady and transient (first order and BDF2) with dual iterations per time step, data sampling.
- Models: laminar, k-ω SST (Menter 2003), standard and realizable k-ε, Spalart–Allmaras; y⁺-insensitive (Reichardt) wall treatment and standard wall functions; exact wall distance (k-d tree).
- Energy with conjugate heat transfer (solid zones, harmonic interface conductivity), Boussinesq and incompressible-ideal-gas buoyancy, thermal wall functions; passive (user-defined) scalars.
- Wind energy: actuator-disk cell zones (thrust ½ρA·Ct·U² spread over the disk), a neutral atmospheric-boundary-layer inlet (Richards–Hoxey log-law U, k, ε/ω from a reference wind speed, height and roughness length), and orthotropic solid conductivity (kx, ky, kz, e.g. FR-4 boards).
- Porous zones (Darcy + inertial), MRF rotating zones, momentum/energy sources (constants or expressions), power-law and Sutherland viscosity.
- Boundary types: velocity inlet, mass-flow inlet, pressure inlet/outlet with backflow, outflow, wall (stationary/moving/rotating, no-slip/slip, temperature/heat-flux/convection), symmetry, pressure far field.
- Named expressions (`4*Umax*y*(H-y)/H^2`, functions of x, y, z, t) anywhere a value is entered.
- Hybrid (potential-flow Laplace) and standard initialization, patching by box/sphere/cylinder.
- Fluent-convention scaled residuals and convergence criteria; report definitions (surface averages, integrals, mass flow, volume statistics, forces, drag/lift/moment coefficients, heat transfer rate) monitored per iteration or time step.

**OpenFOAM backend** (ESI OpenFOAM v2xxx; built on Chisel's OpenFOAM driver)
- Select *OpenFOAM* as the backend (General, Run Calculation or the OpenFOAM page) and Calculate writes the case, runs it stage by stage (`checkMesh`, `decomposePar`, optional `potentialFoam`, the solver under `mpirun -np N … -parallel`, `reconstructPar`, user stages), streams residuals into the Scaled Residuals plot and report definitions into Report Plots, and loads the latest time back into Curlew. Contours, vectors, pathlines, XY plots, reports, VTK export and `.curlew` packages then work on the OpenFOAM solution. Stop terminates the run cleanly.
- Installations are found automatically: the openfoam.com `.app` (its disk image is mounted on demand), a source/Homebrew tree with `etc/bashrc`, or a bundle such as SimFlow's. Cases run in `~/CurlewFoam/<title>` by default because OpenFOAM rejects paths with spaces; Curlew refuses to clean a non-empty folder that is not an OpenFOAM case.
- Applications: simpleFoam, pimpleFoam, pisoFoam, icoFoam, potentialFoam, buoyantBoussinesqSimpleFoam/PimpleFoam, buoyantSimpleFoam/PimpleFoam, rhoSimpleFoam, rhoPimpleFoam, rhoCentralFoam, chtMultiRegionSimpleFoam/chtMultiRegionFoam, chosen automatically from the setup (steady/transient, energy, Boussinesq/incompressible-ideal-gas/ideal-gas density, density-based, solid zones; LES/DES pick a transient solver) or set by hand.
- **Conjugate heat transfer**: a mesh with solid cell zones is split into one fluid region and one region per solid zone, with each fluid–solid or solid–solid face pair written as `mappedWall` patches and coupled by `turbulentTemperatureRadCoupledMixed`. Solids get `heSolidThermo` from their material, external thermal conditions and volumetric heat sources (constant or expression). The run uses `-allRegions`/`-region` utilities in serial or parallel, and the regions are mapped back onto the Curlew mesh, so the temperature field is continuous across fluid and solid for post-processing.
- **Multiple fluids, radiation, rough walls**: each fluid material in a conjugate case becomes its own region, so an air-cooled board and a water cold plate can share one case. Radiation uses fvDOM (discrete ordinates, transparent or participating gas) or P1, with wall emissivity; solid–fluid interfaces exchange radiative flux through `qr`, and the case switches to buoyantSimple/PimpleFoam. Orthotropic solids are written as `constAnIso`. Atmospheric-boundary-layer inlets become `atmBoundaryLayerInlet*`, rough terrain becomes `atmNutkWallFunction` with z₀, and actuator disks become `actuationDiskSource` (Froude, sampling the wind at an upstream point). MRF zones whose patches are not axisymmetric about the rotation axis are flagged.
- **Robust on tetrahedral CAD meshes**:
  - Scalars convected at second order get cell-limited gradients.
  - Meshes with tetrahedra use Green–Gauss gradients. OpenFOAM's least-squares gradient seeds a slow instability in near-wall tetrahedra with two boundary faces.
  - The non-orthogonal correction is limited from 60°, with an extra corrector.
  - Heat-transfer cases get a `limitTemperature` safety net.
  - Initial velocities from the hybrid initialization are capped.
- Turbulence: every Curlew model plus RNG and Launder–Sharma k-ε, Wilcox k-ω, LES (Smagorinsky, WALE, k-equation, dynamic k-equation) and DES/DDES/IDDES (Spalart–Allmaras and k-ω SST), with Spalding, log-law or low-Re wall treatment and the LES filter width.
- Mapped from the Curlew setup: materials (constant, power-law, Sutherland viscosity; constant, Boussinesq, incompressible and ideal-gas density), every boundary type including expression profiles (written as nonuniform lists when they vary in space, and as OpenFOAM `exprFixedValue` conditions when they vary in time: velocity, pressure and temperature), moving/rotating/slip walls, temperature, heat-flux and convection walls, turbulence inlet specifications, pressure far field, gravity, porous zones (DarcyForchheimer), momentum and energy sources (fvOptions; expression sources become `exprField` sources evaluated by OpenFOAM at cell centres and time), MRF zones, passive scalars (scalarTransport), reports (forceCoeffs, forces, surfaceFieldValue, volFieldValue), y⁺, wall shear stress, probes, data sampling (fieldAverage), schemes and relaxation. Initial fields come from Curlew's own initialization (or the current Curlew solution, so OpenFOAM can continue a Curlew run), uniform values or potentialFoam; a run can also restart from the latest OpenFOAM time.
- Also on the OpenFOAM page:
  - Run control: start from latest/start time, stop at end time / write now / next write, runTimeModifiable, compression, time precision.
  - A velocity limiter (`limitVelocity`).
  - More function objects: residuals (`solverInfo`), Courant and Mach numbers, pressure coefficient, wall heat flux, turbulence fields, λ₂, and cutting planes written as VTK surfaces.
  - `runTimeControl`, which stops a run when a chosen report settles.
  - **Case Files**: a preview of every generated dictionary and field file, any of which can be replaced by your own text. Replacements are written last and listed for approval when a case is opened from disk.
  - **Periodic patches** (Boundary Conditions › Periodic): any two patches become a `cyclicAMI` pair with a translation (from the patch centroids or given) or a rotation (axis, centre, angle), for matching or non-matching faces. `meanVelocityForce` drives a closed periodic flow.
  - **Baffles** (OpenFOAM page › Baffles and Periodic Flow): fans with a fan curve (Q, Δp), porous jumps (screens, filters, perforated plates: D, I, L) and zero-thickness walls. Curlew writes `createBafflesDict`, with the faces cut by a disk, plate or box, and runs OpenFOAM's `createBaffles` before the solve.
- OpenFOAM settings exposed in the app: installation and case directory, application, turbulence and wall treatment, endTime/deltaT overrides, adjustable time step (maxCo, maxDeltaT), write interval/format/precision/purgeWrite, every fvSchemes entry, linear solver/smoother/preconditioner/tolerances per equation group, SIMPLE/PIMPLE/PISO correctors, consistent, momentum predictor, outer-loop residual control, residualControl, relaxation factors, cores and decomposition method, function objects, raw boundary conditions for any field on any patch, text appended to any generated dictionary, extra files (e.g. `topoSetDict`) and custom stages (e.g. `topoSet`, `setFields`, `postProcess`). Every case also gets an `Allrun`/`Allclean` that runs from a terminal. Custom stages may only start OpenFOAM applications (programs in `FOAM_APPBIN`, `FOAM_SITE_APPBIN` or `FOAM_USER_APPBIN`), and their words are quoted, never interpreted by a shell. A case opened from disk that carries stages, raw function objects, dictionary text, raw boundary conditions or extra files lists them and asks for approval before Curlew first writes or runs it, because OpenFOAM features such as `systemCall`, `#codeStream` and coded boundary conditions can run programs.
- More OpenFOAM settings, each tested on OpenFOAM v2606 (`FoamSettingsMoreTests`):
  - **Turbulence:** k-ω SST-SAS, SST Langtry–Menter transition (ReThetat, γ), GEKO, the LRR and SSG Reynolds-stress models (R, ε), LES sigma and Deardorff differential stress, plus any model coefficient (`<model>Coeffs`, e.g. Cmu, betaStar, Cs).
  - **Boundary conditions per patch** (OpenFOAM page › Boundary Conditions):
    - Inlets: volumetric flow rate; synthetic LES inflow (turbulentDFSEMInlet, from the intensity, length scale and inflow height); a velocity profile from a CSV file of points (timeVaryingMappedFixedValue, written to `constant/boundaryData`).
    - Inlets and outlets: fan curves (fanPressure).
    - Outlets: non-reflecting (advective, or waveTransmissive for compressible solvers).
    - Walls: sand-grain roughness (nutkRoughWallFunction with Ks and Cs).
  - **Thermophysical models:**
    - Transport: const, Sutherland or polynomial μ(T), κ(T).
    - Thermo: constant Cp, JANAF NASA polynomials (with an air preset) or polynomial Cp(T).
    - Equation of state: perfect gas, incompressible perfect gas, ρ = const, perfect fluid, Peng–Robinson real gas, polynomial ρ(T) or Boussinesq.
    - Combinations OpenFOAM is not compiled for are refused, with a list of the ones it has. The energy form (enthalpy or internal energy) follows what OpenFOAM offers.
  - **fvOptions:** blade-element rotors (rotorDisk: blade sections and an airfoil table), fixed-temperature zones (fixedTemperatureConstraint) and velocity damping (velocityDampingConstraint).
  - **Run control and solvers:** writeControl (time steps, simulated, wall-clock or CPU time), pressure reference point and value, hierarchical/simple decomposition split and order, and the linear-solver extras (minIter, nSweeps, GAMG pre/post sweeps, mergeLevels, cacheAgglomeration).
  - **Time averaging:** fieldAverage with any fields, variance, a start time and a window.
  - **Adaptive mesh refinement** (dynamicRefineFvMesh) of hexahedral meshes in transient runs, on a field or an OpenFOAM expression such as `mag(U)`.
- Curlew expressions are translated to OpenFOAM's expression syntax (`x` → `pos().x()`, `t` → `time()`, `^` → `pow`, `if(c,a,b)` → `c ? a : b`, named expressions inlined).

**Density-based solver** (explicit, compressible ideal gas)
- Roe flux-difference splitting (entropy fix) or AUSM+; MUSCL with Venkatakrishnan limiting; 4-stage Runge–Kutta with local time stepping (steady) or SSP-RK3 with a global CFL step (transient); laminar viscous fluxes; characteristic far field, subsonic/supersonic pressure inlet and outlet.

**Linear algebra**
- Aggregation (double-pairwise) AMG with Galerkin operators, V/W/F and Notay K-cycles, flexible CG and BiCGStab, deterministic parallel Gauss–Seidel.
- Metal GPU backend: fp32 AMG-preconditioned CG fully on the GPU (on-device α/β, no per-iteration sync) inside double-precision iterative refinement.

**App**
- Outline tree with task pages for every Setup/Solution/Results node, Metal graphics window (contours smooth or banded, vectors, pathlines, mesh, planes and iso-surfaces, feature-edge outlines, axis triad, five colormaps), scaled-residual and report plots, XY plots, a console with text commands, `.curlew` case packages (case + mesh + data), PNG export with legend, 19 tutorials and an in-app validation suite. The four engineering tutorials are:
  - **Wind farm:** three 80 m turbines in a row as actuator disks in a 10 m/s atmospheric boundary layer, k-ε with rough ground.
  - **Wind-turbine rotor:** the lofted three-blade rotor in a rotating MRF zone at tip-speed ratio 6, k-ω SST, reporting torque coefficient and thrust.
  - **Air-cooled heat sink:** a 10 W chip on an FR-4 board under an aluminium heat sink in a 2 m/s duct.
  - **Liquid cold plate:** a 100 W chip under a copper plate with four water channels.

## Validation

All numbers below are produced by `curlew-cli validate …` (and the app's Validation Suite) on an M3 Pro.

| Case | Quantity | Reference | Curlew |
|---|---|---|---|
| Lid-driven cavity Re=100, 64² | max \|u − u_Ghia\| on vertical centreline | Ghia et al. 1982 | 0.0042 |
| Lid-driven cavity Re=1000, 128² | max \|u − u_Ghia\| / max \|v − v_Ghia\| | Ghia et al. 1982 | 0.0045 / 0.0126 |
| Natural convection Ra=10⁵, 64² | Nusselt number | 4.519 (de Vahl Davis 1983) | 4.526 (+0.16 %) |
| Flat plate, k-ω SST, Re=5×10⁶ | Cf at x = 0.97 | OpenFOAM v2606 kOmegaSST, identical mesh: 0.002652 | 0.002652 |
| Flat plate, Spalart–Allmaras | Cf at x = 0.97 | Kármán–Schoenherr 0.002816 | 0.002736 (−2.9 %) |
| Flat plate, laminar | Cf at x = 0.97 | Blasius 0.000301 | 0.000302 |
| Schäfer–Turek 2D-1 (Gmsh, 35k cells) | C_D / Δp | 5.57–5.59 / 0.1172–0.1176 | 5.579 / 0.1175 |
| Cylinder Re=100 (transient) | St / C_D mean | 0.164–0.166 / 1.33–1.35 | 0.163 / 1.326 |
| Backward-facing step, SST | reattachment x_r/h | OpenFOAM v2606, same mesh: 5.79 | 5.64 |
| NACA 0012, α=10°, SA (25k cells) | C_L | Ladson exp. ≈ 1.07 | 1.066 |
| Turbulent pipe Re=20 000, SST, 14 prism layers + tetrahedra (404k cells, y⁺ 0.94) | Darcy f from dp/dx / from wall shear, x/D 5.5–8.5 | OpenFOAM v2606 kOmegaSST, identical mesh: 0.02419 / 0.02271 | 0.02415 / 0.02298 |
| Schäfer–Turek 3D-1Z (Re=20), 582k tetrahedra | C_D / C_L | 6.1853 / 0.00940 (Bayraktar et al. 2012) | 6.267 (+1.3 %) / 0.0080 |
| Same, 8 prism layers on the cylinder (678k cells) | C_D / C_L | 6.1853 / 0.00940 | 6.293 (+1.7 %) / 0.0098 (+4 %) |
| Sod shock tube, 400 cells | L1 density error at t = 0.2 | exact Riemann solution | 0.0019 |
| Mach 2.5, 15° ramp | p₂/p₁ / shock angle | 2.4696 / 36.96° (oblique-shock theory) | 2.4678 / 36.94° |

Analytic checks in the unit tests: plane Poiseuille flow (profile and dp/dx within 1 %), 1D conduction with a source (error equals the expected q·Δx²/8k), composite-wall CHT (exact to 10⁻⁶ K), porous slab pressure drop (converges with refinement: 2.8 % → 0.4 % for 4× cells), Sod shock tube, cavity, mesh/solution file round trips.

3D prism layers are checked with OpenFOAM `checkMesh` ("Mesh OK") and by unit tests on a tetrahedral cube: volume is conserved to 10⁻¹⁰, first-layer centres sit at h₁/2, and inlet faces gain one side quad per layer. An oversized stack is thinned without inverting or flattening cells. The 3D-1Z geometry and case are in `Examples/schafer-turek-3d`.

**OpenFOAM backend** — the same benchmark code, fed with OpenFOAM fields read back by Curlew (`curlew-cli validate … --backend openfoam`, OpenFOAM v2606):

| Case | Quantity | Reference | Curlew → OpenFOAM |
|---|---|---|---|
| Lid-driven cavity Re=100, 64² (simpleFoam) | max \|u − u_Ghia\| / max \|v − v_Ghia\| | Ghia et al. 1982 | 0.0044 / 0.0091 (377 iterations, 2.8 s) |
| Natural convection Ra=10⁵, 64² (buoyantBoussinesqSimpleFoam) | Nusselt number, u_max, v_max | 4.519, 34.73, 68.59 | 4.526 (+0.15 %), 34.86, 68.89 |
| Flat plate, k-ω SST (simpleFoam, 4 cores) | Cf at x = 0.97 | Curlew 0.002652 | 0.002659 |
| Cylinder Re=100 (pimpleFoam, 4 cores) | St | 0.164–0.166 | 0.163 |
| Sod shock tube, 400 cells (rhoCentralFoam, Kurganov) | L1 density error at t = 0.2 | exact Riemann solution | 0.0114 (Curlew's Roe/MUSCL/RK: 0.0019) |
| Mach 2.5, 15° ramp (rhoCentralFoam, 4 cores) | p₂/p₁ / shock angle | 2.4696 / 36.96° | 2.4687 / 36.98° |

| Composite wall, two solids k = 1 / 4 (chtMultiRegionSimpleFoam) | T profile / heat flux | exact: 400→320→300 K, 160 W/m² | within 0.01 K / 2 % |
| Stagnant fluid slab against a solid (fluid–solid coupling) | T profile / heat flux | exact series resistance | within 0.01 K / 2 % |
| Cooled chip CHT tutorial (4 cores) | inlet pressure / chip T_max / heat out | Curlew 0.023223 Pa / 368.7 K / 0.2 W | 0.023266 Pa / 371.8 K / 0.19999 W |
| Taylor–Couette with an MRF zone around the rotor | u_θ at r = 0.75, 1.25, 1.6 | exact A r + B/r | within 0.7 % (Curlew within 2 %) |
| Channel, ideal gas at M ≈ 3·10⁻⁴ (rhoSimpleFoam) | pressure drop | simpleFoam on the same mesh | within 3 %, mass conserved to 10⁻³ |
| Heated ceiling, incompressible ideal gas with gravity (buoyantSimpleFoam) | heat out of the outlet | 0.2 W added at the wall | within 3 % |
| Periodic plane channel (cyclicAMI + meanVelocityForce) | u(y) | exact Poiseuille profile 6Ū y(H−y)/H² | within 2 % of u_max |
| Fan baffle with a flat 0.5 Pa curve (createBaffles, fan) | inlet pressure change | −0.5 Pa | within 0.05 Pa |
| Porous jump, Darcy only, uniformJump (porousBafflePressure) | inlet pressure change | D μ Ū L | within 5 % |

**Engineering tutorials and CAD analysis**: both backends on the same mesh. Energy balances are exact references; the rest are cross-checks.

| Case | Quantity | Reference | Curlew | OpenFOAM |
|---|---|---|---|---|
| Liquid cold plate (68k hex cells, laminar water, FR-4 board) | heat into water / Δp / chip T_max | 100 W in | 99.997 W / 37.0 Pa / 339.3 K | 100.1 W / 37.6 Pa / 343.0 K |
| Air-cooled heat sink (74k hex cells, SST) | heat into air / Δp / chip T_max | 10 W in | 9.993 W / 1.11 Pa / 324.3 K | 9.998 W / 1.35 Pa / 334.0 K |
| CAD heat sink sample (Gmsh tetrahedra, conjugate) | heat into air / solid T_max | 10 W in | not run | 9.99 W / 309.9 K |
| CAD pipe elbow sample (D = 50 mm, water 1 m/s, SST, 12 prism layers) | mass in / out, Δp | mass conservation | 1.92443 / 1.92443 kg/s, 320 Pa | — |
| CAD NACA 0012 wing sample (AR 4, 4°, coarse tetrahedra, no layers) | C_L / C_D (planform reference) | lifting-line C_L ≈ 0.29 | — | 0.154 / 0.082 (coarse mesh under-predicts lift) |
| CAD example `Examples/CAD/manifold.step` (mm), dead-ended header, water 0.5 m/s, SST, 60 886 cells | branch flow split / mass balance | mass conservation; dividing-manifold trend | — | 31.5 / 33.5 / 35.0 % (rising toward the closed end); in = out to 10⁻⁵ |
| PINN, lid-driven cavity Re = 100 (physics only, 6×64 tanh, 10 000 Adam + 2000 L-BFGS (the defaults), CPU, 7.3 min) | max \|u − u_Ghia\| / max \|v − v_Ghia\| | Ghia et al. 1982 | 0.024 / 0.025 | — |
| PINN, same cavity, hybrid (physics + 4096 CFD samples, 3000 Adam + 1000 L-BFGS, Apple GPU, 2.5 min) | max \|u − u_Ghia\| / max \|v − v_Ghia\| | Ghia et al. 1982 (the CFD data itself: 0.004 / 0.009) | 0.0057 / 0.0086 | — |
| Wind farm, 3 actuator disks, ABL, k-ε | disk-averaged wind speed, turbines 1–3 | 1-D momentum theory: 7.5 m/s at the first disk | 7.34 / 5.41 / 5.11 m/s | 8.08 / 7.68 / 7.51 m/s (27 s on 4 cores) |
| Wind-turbine rotor, MRF, SST (198k tetrahedra) | C_m (C_p = 6 C_m) / thrust | — | does not converge | 0.0345 (C_p ≈ 0.21) / 102 N |

Known limits:
- **Wind farm:** the two backends disagree on wake recovery. OpenFOAM's wakes recover faster than a Jensen engineering wake model, which puts turbine 2 at about 0.88 of turbine 1. That is the known bias of the standard k-ε model, whose eddy viscosity is too high in wakes. The realizable k-ε model or a finer mesh (the module's *cells per diameter*) is the first thing to try.
- **Prism layers at sharp edges:** layers can fold at sharp trailing edges and wing tips. CAD Analysis checks the face pyramids (the same test as OpenFOAM's checkMesh) and remeshes without layers when they fold.
- **Air-cooled heat sink:** Curlew's continuity residual plateaus near 10⁻¹, probably because the wake behind the fins is unsteady.
- **Wind-turbine rotor:** Curlew's own solver diverges on this mesh, so the tutorial defaults to the OpenFOAM backend.
| Heater zone with a source `2e4*(1 + x)` and inlet `0.1*(1 + 10*t)` | inlet mass flow at t = 0.1 | 1.225 × 0.2 × A | within 10⁻³ |

CAD → snappyHexMesh checks: an STL sphere (external flow, 3 layers, 4 cores) gives 364k cells with checkMesh OK and 100 % layer coverage; a STEP sudden expansion written in millimetres (internal flow) is tessellated, snapped and layered to a fluid volume of 2.548 m³ against the exact 2.553 m³, and solves with kOmegaSST on 4 cores from Curlew's initialization.

Meshing checks for the new formats: an STL/OBJ/PLY/OFF/3MF/glTF/GLB/AMF/VTK/FreeCAD sphere meshes to the same domain in every format; the glTF node transform (scale 2, translation +1 m) is applied. Internal flow finds the inlet, outlet and branch `outlet_ymin` of a STEP tee and the `outlet_ymax` of an elbow in Gmsh and snappyHexMesh (tee: checkMesh OK, 98 % layer coverage).

**Notes on behaviour found during validation**
- The pressure-force gradient matters on prism/tetrahedron meshes. With a plain least-squares pressure source, the force on the fluid in the turbulent pipe was 4.8 % smaller than the pressure difference across it. The flow was right (wall shear matched OpenFOAM), but the pressure drop was 4.7 % high. The conservative gradient matches OpenFOAM's pressure drop to 0.2 % and improves 3D-1Z lift from −75 % to −15 % (tetrahedra) and to +4 % (prisms). `methods.conservativePressureGradient = false` restores the old source.
- The 10-diameter pipe starts from a 1/7-power profile and is not fully developed (wall shear still falls at x/D = 9). Both Curlew and OpenFOAM sit 7–12 % below the smooth-pipe correlations there. Use the identical-mesh comparison for this case, not the correlations.
- Sphere at Re = 100 in the CAD tutorial's box (symmetry planes 3.5 D away): drag decreases with refinement (1.183 → 1.175 → 1.165 on 113k–1.03M cells with prism layers). It stays above the unconfined 1.087 because of blockage and the coarse wake. OpenFOAM on the identical tetrahedral mesh gives 1.243 (Curlew 1.203).
- Steady RANS of the 3D mixing tee does not converge in either Curlew or OpenFOAM (the jet-in-crossflow separation is unsteady), so that tutorial runs transient.
- The turbulent transpose stress term is optional (off by default for constant molecular viscosity): it changes results by < 1 % but slows convergence of separated flows. It is always on for non-Newtonian/Sutherland fluids.
- Fluent-style residual normalisation can report convergence early after a potential-flow initialization; the airfoil tutorial therefore uses tight criteria — watch the force monitors.
- OpenFOAM's heRhoThermo Boussinesq enthalpy includes p/ρ, so with the benchmark's Cp = 1 a 10 Pa hydrostatic change looks like 10 K and buoyantSimpleFoam diverges. Constant-density and Boussinesq heat transfer therefore use buoyantBoussinesqSimpleFoam/PimpleFoam, which solve temperature directly. Those solvers have no SIMPLEC, so a SIMPLEC setup is written as SIMPLE with OpenFOAM's buoyant-tutorial relaxation (p 0.7, U 0.3, T 0.5).
- rhoCentralFoam is explicit, so Curlew always runs it with an adjustable time step: the first step is sized from the smallest cell and the fastest acoustic wave, and maxCo is capped at 0.2 (the OpenFOAM tutorials' value; 0.5 diverged on the ramp). A steady density-based setup runs its iteration count as pseudo-time steps. Supersonic inflow (inlet or far-field Mach ≥ 1) fixes U, p and T at the inflow and extrapolates them at pressure outlets; a far field is specified by Mach number, as in Curlew's density-based solver.
- Comparing the CHT chip with OpenFOAM exposed a bug in Curlew's own solver. Fluid cells next to a solid used the solid cells' (meaningless) pressure in the least-squares and conservative pressure gradients, which lowered the channel's pressure drop by 5 % and raised the heat-transfer coefficient. Fluid–solid faces are now zero-gradient walls for the pressure gradient. Curlew and OpenFOAM then agree on the flow to 0.2 %, and the chip's temperature rise differs by 4.5 % (68.7 K vs 71.8 K) where it differed by 12 % before. Both conserve the 0.2 W.
- On a square (non-axisymmetric) MRF zone with no moving walls, the exact solution is quiescent. Curlew gives zero velocity there, while OpenFOAM shows spurious flow at the zone boundary, a known MRF artefact. MRF zones should be surfaces of revolution, as in the Taylor–Couette check.
- Steady heat-transfer cases use PBiCGStab/DILU for the energy equation and relax it to 0.7 at most. With smoothSolver, the diffusion-dominated first iteration of a heated channel did not converge, and the density collapsed.
- The residuals plotted for OpenFOAM runs are OpenFOAM's initial residuals (what residualControl judges), not Fluent-scaled ones; they are mapped onto Curlew's equation names.

## Performance (M3 Pro, 262k-cell 3D cavity)

- ~97 ms per SIMPLEC iteration on the CPU (all cores, deterministic reductions).
- 1M-unknown pressure system to 10⁻⁶: CPU AMG-FCG 0.45 s, Metal GPU 0.29 s (1.5×), GPU solution identical to the CPU one to 10⁻⁸.
- 3D duct and cavity: 50–200 iterations to 10⁻⁶; flat plate SST: 14 s; cylinder wake (4,000 time steps): 110 s.

## Build and install

Requirements: macOS 15+, Xcode 16+ (Swift 6). Optional: Gmsh.app in `/Applications` for the Gmsh templates and CAD import; an ESI OpenFOAM (the openfoam.com `.app`, or any tree with `etc/bashrc`) for the OpenFOAM backend and snappyHexMesh; ParaView for *Open in ParaView*.

```bash
Scripts/build-app.sh            # → dist/Curlew.app (release, ad-hoc signed)
Scripts/build-app.sh install    # also copies it to /Applications
swift test -c release           # unit and analytic tests
```

The app icon is drawn by `Scripts/make-icon.swift` (`Assets/AppIcon.icns`). The bundle is ad-hoc signed for this Mac; distributing it to others needs a Developer ID signature and notarization.

## Command line

The CLI ships inside the bundle at `Curlew.app/Contents/Helpers/curlew` (and as `.build/release/curlew-cli`).

```bash
curlew-cli tutorial flat-plate --vtu plate.vtu
curlew-cli validate cavity --re 1000 --cells 128
curlew-cli run case.json --mesh mesh.msh --save result.curlew --vtu result.vtu
curlew-cli run result.curlew --continue --iterations 500
curlew-cli mesh-cad part.step --axis 0 --max-size 0.2 --wall-size 0.02 --bl-first 2e-4 --bl-growth 1.2 --bl-layers 12
curlew-cli mesh-pipe --bl-first 2e-4 --bl-layers 8 --foam ./checkCase      # then OpenFOAM checkMesh there
curlew-cli validate pipe --re 20000            # turbulent friction factor on prism layers (--tet-only to compare)
curlew-cli run Examples/schafer-turek-3d/case.json --mesh channel.msh --bl-first 0.001 --bl-layers 8 --bl-zones cylinder
curlew-cli export result.curlew --foam ./foamCase
curlew-cli mesh-cad part.stl --unit mm --internal --bl-first 1e-4 --bl-layers 8        # STL/OBJ/PLY/OFF/3MF through Gmsh
curlew-cli foam detect                                                             # OpenFOAM installations
curlew-cli foam mesh body.step --unit mm --levels 3,5 --layers 5 --cores 8 --save body.curlew   # snappyHexMesh
curlew-cli foam run body.curlew --turbulence kOmegaSST --cores 8 --iterations 1000 --save result.curlew
curlew-cli foam run case.json --mesh mesh.msh --app pimpleFoam --dir ~/CurlewFoam/run1 --write-only
curlew-cli validate cavity --backend openfoam                                      # benchmarks on either backend
curlew-cli foam run --tutorial cht-chip --cores 4                                  # conjugate heat transfer (chtMultiRegionSimpleFoam)
curlew-cli samples                                                                 # build the CAD samples as STEP in ~/CurlewFoam/samples
curlew-cli cad-analysis sample:heatSink --level coarse --run --backend openfoam --cores 4   # CAD → mesh → case → run
curlew-cli cad-analysis part.step --type external --axis 0 --speed 30 --unit mm --run       # drag and lift of your own model
CURLEW_CAD_CONVERTER="ExchangerConv -i {input} -e {output}" curlew-cli mesh-cad part.sldprt --internal   # native CAD via a converter
```

Case files are JSON (`CaseSetup`); any field may be omitted and takes the Fluent-like default. Minimal example:

```json
{
  "title": "channel",
  "models": { "viscous": "k-omega-sst" },
  "boundaries": {
    "inlet":  { "type": "velocity-inlet", "velocityMagnitude": 2.0, "turbulentIntensity": 0.05 },
    "outlet": { "type": "pressure-outlet" }
  },
  "run": { "iterations": 800 }
}
```

Case JSON can carry an `"openfoam"` object with any `FoamSettings` key, e.g. `{"general": {"backend": "openfoam"}, "openfoam": {"cores": 8, "turbulence": "kOmegaSSTDDES", "schemes": {"divU": "Gauss LUST grad(U)"}}}`.

**Python post-processing** (Post-Processing › Python scripts, `curlew-cli post-script`). OpenFOAM computes derived fields, samples and expression fields; free-form analysis of a finished solution is what it has no interface for. Curlew exports a time directory of any single-region OpenFOAM case as NumPy arrays and runs your script with the `curlew_post` module:

```python
import numpy as np
import curlew_post as cp

case = cp.load()                         # time, cells (centres, volumes), every volume field
U, p = case["U"], case.pressure_pa()     # (n, 3) and (n,) arrays; pressure in Pa
inlet = case.patches["inlet"]            # face centres, area vectors, field values on faces
cp.report("inlet flow", -inlet.flux("U"), "m3/s")          # shown in Curlew
s, u = case.line([0.5, 0, 0], [0.5, 1, 0], n=200, field="U")
forces = case.function_object("forceCoeffs")                 # postProcessing/ output as arrays
case.write_field("speed", np.linalg.norm(U, axis=1))          # new field for ParaView and Curlew
cp.savefig("profile")                                         # Matplotlib figure shown in Curlew
```

- **Templates:** patch summary, pressure drop, a line plot, a total-pressure field, the residual history and field statistics.
- **Where it runs:** scripts run with the Python from Settings › Machine Learning (the PyTorch environment has NumPy and Matplotlib), in isolated mode and never through a shell. A script can run on demand, or after each solve once the case content is approved.
- **Safety:** scripts saved in a case are listed for approval like any other active content. `curlew-cli post-script case.curlew` needs `--trust-case-content`.
- **Check:** on the Re = 1000 cavity, a script's vertical-centreline minimum u is −0.3837, against −0.3829 from Ghia et al. (1982).

```bash
curlew-cli post-script --case ~/CurlewFoam/run1 --script Examples/post-scripts/analysis.py [--time 500]
curlew-cli post-script result.curlew --name pressure_drop --trust-case-content
curlew-cli post-script --templates
```

The app console accepts text commands (`help` lists them), e.g. `/tutorial cavity`, `/solve/iterate 500`, `/display/contour pressure`, `/report/forces`, `/surface/plane mid z 0.5`, `/plot/xy temperature 0 0 0 1 0 0`, `/file/write-case ~/case.curlew`, `/define/backend openfoam`, `/openfoam/set cores 8`, `/openfoam/run`, `/mesh/cad ~/part.step snappy unit=mm`. Setting `CURLEW_SCRIPT="cmd1; cmd2"` runs commands at launch.

## Layout

```
Sources/CurlewMesh     mesh data structure, geometry, quality, readers/writers, block mesher, Gmsh driver
Sources/CurlewLinear   CSR matrices, AMG, Krylov solvers, Metal GPU backend, deterministic parallel helpers
Sources/CurlewSolver   case model, pressure- and density-based solvers, turbulence, energy, reports, benchmarks, tutorials
Sources/CurlewPost     surfaces, node interpolation, planes/iso-surfaces, vectors, pathlines, VTK/CSV export
Sources/CurlewFoam     OpenFOAM backend: discovery, case writer, staged runner, log parser, field reader, snappyHexMesh
Sources/CurlewApp      SwiftUI app and Metal renderer
Sources/CurlewCLI      batch interface, validation and benchmarks
Tests/CurlewTests      unit, analytic and round-trip tests
```

## Compared with Ansys Fluent

Curlew covers the core of a general-purpose CFD code; Fluent is a much larger product built
over decades. The main gaps, grouped by area:

**Physics models not in Curlew**
- Multiphase: VOF, mixture, Eulerian (incl. boiling, wet steam), population balance, cavitation, Eulerian wall film.
- Discrete phase (particle tracking, DPM/DEM coupling, sprays, erosion).
- Species transport with mixture properties, combustion (finite-rate/EDC, non-premixed and premixed flamelets, partially premixed), pollutants (NOx, soot).
- Radiation in Curlew's own solver (DO and P-1 run through the OpenFOAM backend); S2S, Rosseland and solar load.
- Turbulence in Curlew's own solver: LES, DES/SBES/SAS (LES and DES run through the OpenFOAM backend), transition models (γ-Reθ, intermittency, k-kl-ω), Reynolds-stress models, GEKO/BSL/standard k-ω, enhanced wall treatment, sand-grain wall roughness (aerodynamic roughness z₀ runs through the OpenFOAM backend), curvature/rotation corrections. Turbulence with the density-based solver.
- Real-gas models, temperature-dependent (polynomial/piecewise) material properties, Carreau/Cross/Herschel–Bulkley fluids, multicomponent diffusion.
- Solidification/melting, battery (MSMD, NTGK), fuel cells and electrochemistry, aeroacoustics (FW-H, broadband sources), fluid–structure interaction coupling, shell conduction.

**Mesh and motion**
- Fluent Meshing (watertight and fault-tolerant workflows, surface wrapping, poly-hexcore/mosaic meshes). Curlew relies on its block mesher and Gmsh, adding its own prism inflation on 3D walls. That inflation does not do Fluent's layer collision handling at sharp concave corners or last-ratio/aspect-ratio growth options; stacks are thinned there instead.
- Polyhedral conversion, mesh adaption (hanging-node refinement), dynamic mesh (smoothing, layering, remeshing, 6-DOF), sliding mesh, overset, non-conformal mesh interfaces, translational/rotational periodicity.
- Fan, radiator, porous-jump and baffle face conditions; non-reflecting boundaries; boundary profiles from files.

**Solver numerics**
- Coupled pressure-based solver, pseudo-transient, non-iterative time advancement, adaptive time stepping, PRESTO! pressure, implicit density-based solver, FMG initialization.

**Scale and performance**
- Distributed-memory (MPI) parallel runs across nodes and clusters; Curlew runs on one Mac's cores.
- Fluent's native multi-GPU solver runs the whole solver on GPUs; Curlew offloads only the pressure linear solve (≈1.5× on that step, ≈14 % per iteration).
- Curlew has been exercised up to about one million cells.

**Customisation, automation and post-processing**
- UDFs (C), Scheme/TUI journals and PyFluent; Curlew has a small console command set, JSON cases and a CLI.
- Parametric studies and design points, adjoint solver and shape optimisation, reduced-order models, Workbench/Mechanical coupling.
- Animations and scenes, custom field functions, histograms/FFT, particle tracks, CGNS/EnSight export, unit systems (Curlew is SI only), automatic export during runs.

**Pedigree**
- Fluent has industrial validation across many sectors and robustness on difficult meshes; Curlew is validated on the benchmarks listed above.
