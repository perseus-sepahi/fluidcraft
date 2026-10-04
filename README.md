# Curlew

A native macOS computational fluid dynamics application built around the Fluent-style
workflow (Mesh → Setup → Solution → Results). Unstructured finite-volume pressure-based and
density-based solvers in Swift, a Metal graphics window, aggregation AMG with an optional
Metal GPU backend, Gmsh-driven meshing (including STEP/IGES import), and a validation suite
that reproduces published benchmarks.

© 2026 Perseus Sepahi

## What is in it

**Meshing**
- Structured block mesher (2D slabs and 3D, graded segments, rectangular obstacles, box-defined solid/porous cell zones, named patches) and a 2D cylinder O-grid.
- Gmsh workflow (uses `/Applications/Gmsh.app`): channel + cylinder, NACA 4-digit airfoil in a far field with boundary-layer quads, 3D pipe, and **CAD import** (STEP/IGES/BREP) for external flow (body subtracted from a box) or internal flow, with inlet/outlet/far-field/wall named selections assigned automatically.
- **3D prism boundary layers (inflation)** on the Gmsh pipe and CAD meshes: first-layer height, growth rate and number of layers, with a y⁺ calculator that sizes the first layer. The tetrahedral mesh is pushed away from the walls along smoothed normals, the displacement is relaxed into the surrounding cells, and the gap is filled with prism stacks. The layers slide along inlets, outlets and symmetry planes. Where the volume mesh lacks room, a stack is thinned locally; the first-layer height is kept and the growth rate is reduced instead. Every insertion is checked for inverted or folded cells, and the generated meshes pass OpenFOAM `checkMesh`.


  ![Prism layers in the turbulent pipe tutorial](Docs/prism-layers.png)
  *Cross-section of the turbulent pipe tutorial: 14 graded prism layers (first cell at y⁺ ≈ 0.94) under the tetrahedral core, coloured by axial velocity.*
- Importers: Fluent `.msh`/`.cas` (ASCII and binary, 2D and 3D, mixed/polygonal faces, multiple cell zones), Gmsh `.msh` 2.2/4.1 (all linear element types; higher-order reduced to corners), OpenFOAM `polyMesh` (ASCII/binary/gzip).
- Exporters: Fluent ASCII `.msh`, OpenFOAM case (mesh, `0/`, `constant/`, `system/` for simpleFoam/pimpleFoam), ParaView `.vtu` (polyhedral cells), CSV.
- Mesh check: Fluent-style orthogonal quality, aspect ratio, non-orthogonality, volume statistics; zone renaming/retyping.

**Pressure-based solver** (cell-centred, collocated, face-based polyhedral)
- SIMPLE, SIMPLEC, PISO; Rhie–Chow with under-relaxation and time-step consistency terms.
- Least-squares and Green–Gauss gradients; the pressure force uses a conservative Green–Gauss gradient with skewness-corrected face values, which is exact for linear fields like least squares, but the pressure force on any region equals the pressure integral over its boundary; first/second-order upwind, central, bounded central, QUICK and MUSCL convection with TVD (van Leer) bounding; over-relaxed non-orthogonal correction with automatic limiting.
- Pressure interpolation: Standard (momentum-weighted at porous interfaces), Second Order (limited extrapolation), Body Force Weighted.
- Steady and transient (first order and BDF2) with dual iterations per time step, data sampling.
- Models: laminar, k-ω SST (Menter 2003), standard and realizable k-ε, Spalart–Allmaras; y⁺-insensitive (Reichardt) wall treatment and standard wall functions; exact wall distance (k-d tree).
- Energy with conjugate heat transfer (solid zones, harmonic interface conductivity), Boussinesq and incompressible-ideal-gas buoyancy, thermal wall functions; passive (user-defined) scalars.
- Porous zones (Darcy + inertial), MRF rotating zones, momentum/energy sources (constants or expressions), power-law and Sutherland viscosity.
- Boundary types: velocity inlet, mass-flow inlet, pressure inlet/outlet with backflow, outflow, wall (stationary/moving/rotating, no-slip/slip, temperature/heat-flux/convection), symmetry, pressure far field.
- Named expressions (`4*Umax*y*(H-y)/H^2`, functions of x, y, z, t) anywhere a value is entered.
- Hybrid (potential-flow Laplace) and standard initialization, patching by box/sphere/cylinder.
- Fluent-convention scaled residuals and convergence criteria; report definitions (surface averages, integrals, mass flow, volume statistics, forces, drag/lift/moment coefficients, heat transfer rate) monitored per iteration or time step.

**Density-based solver** (explicit, compressible ideal gas)
- Roe flux-difference splitting (entropy fix) or AUSM+; MUSCL with Venkatakrishnan limiting; 4-stage Runge–Kutta with local time stepping (steady) or SSP-RK3 with a global CFL step (transient); laminar viscous fluxes; characteristic far field, subsonic/supersonic pressure inlet and outlet.

**Linear algebra**
- Aggregation (double-pairwise) AMG with Galerkin operators, V/W/F and Notay K-cycles, flexible CG and BiCGStab, deterministic parallel Gauss–Seidel.
- Metal GPU backend: fp32 AMG-preconditioned CG fully on the GPU (on-device α/β, no per-iteration sync) inside double-precision iterative refinement.

**App**
- Outline tree with task pages for every Setup/Solution/Results node, Metal graphics window (contours smooth or banded, vectors, pathlines, mesh, planes and iso-surfaces, feature-edge outlines, axis triad, five colormaps), scaled-residual and report plots, XY plots, a console with text commands, `.curlew` case packages (case + mesh + data), PNG export with legend, 15 tutorials and an in-app validation suite.

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

**Notes on behaviour found during validation**
- The pressure-force gradient matters on prism/tetrahedron meshes. With a plain least-squares pressure source, the force on the fluid in the turbulent pipe was 4.8 % smaller than the pressure difference across it. The flow was right (wall shear matched OpenFOAM), but the pressure drop was 4.7 % high. The conservative gradient matches OpenFOAM's pressure drop to 0.2 % and improves 3D-1Z lift from −75 % to −15 % (tetrahedra) and to +4 % (prisms). `methods.conservativePressureGradient = false` restores the old source.
- The 10-diameter pipe starts from a 1/7-power profile and is not fully developed (wall shear still falls at x/D = 9). Both Curlew and OpenFOAM sit 7–12 % below the smooth-pipe correlations there. Use the identical-mesh comparison for this case, not the correlations.
- Sphere at Re = 100 in the CAD tutorial's box (symmetry planes 3.5 D away): drag decreases with refinement (1.183 → 1.175 → 1.165 on 113k–1.03M cells with prism layers). It stays above the unconfined 1.087 because of blockage and the coarse wake. OpenFOAM on the identical tetrahedral mesh gives 1.243 (Curlew 1.203).
- Steady RANS of the 3D mixing tee does not converge in either Curlew or OpenFOAM (the jet-in-crossflow separation is unsteady), so that tutorial runs transient.
- The turbulent transpose stress term is optional (off by default for constant molecular viscosity): it changes results by < 1 % but slows convergence of separated flows. It is always on for non-Newtonian/Sutherland fluids.
- Fluent-style residual normalisation can report convergence early after a potential-flow initialization; the airfoil tutorial therefore uses tight criteria — watch the force monitors.

## Performance (M3 Pro, 262k-cell 3D cavity)

- ~97 ms per SIMPLEC iteration on the CPU (all cores, deterministic reductions).
- 1M-unknown pressure system to 10⁻⁶: CPU AMG-FCG 0.45 s, Metal GPU 0.29 s (1.5×), GPU solution identical to the CPU one to 10⁻⁸.
- 3D duct and cavity: 50–200 iterations to 10⁻⁶; flat plate SST: 14 s; cylinder wake (4,000 time steps): 110 s.

## Build and install

Requirements: macOS 15+, Xcode 16+ (Swift 6). Gmsh.app in `/Applications` for the Gmsh templates and CAD import (optional).

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

The app console accepts text commands (`help` lists them), e.g. `/tutorial cavity`, `/solve/iterate 500`, `/display/contour pressure`, `/report/forces`, `/surface/plane mid z 0.5`, `/plot/xy temperature 0 0 0 1 0 0`, `/file/write-case ~/case.curlew`. Setting `CURLEW_SCRIPT="cmd1; cmd2"` runs commands at launch.

## Layout

```
Sources/CurlewMesh     mesh data structure, geometry, quality, readers/writers, block mesher, Gmsh driver
Sources/CurlewLinear   CSR matrices, AMG, Krylov solvers, Metal GPU backend, deterministic parallel helpers
Sources/CurlewSolver   case model, pressure- and density-based solvers, turbulence, energy, reports, benchmarks, tutorials
Sources/CurlewPost     surfaces, node interpolation, planes/iso-surfaces, vectors, pathlines, VTK/CSV export
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
- Radiation (DO, S2S, P-1, Rosseland, solar load).
- Turbulence: LES, DES/SBES/SAS, transition models (γ-Reθ, intermittency, k-kl-ω), Reynolds-stress models, GEKO/BSL/standard k-ω, enhanced wall treatment, wall roughness, curvature/rotation corrections. Turbulence with the density-based solver.
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
