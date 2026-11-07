# OpenFOAM v2606 features Curlew does not expose yet

Curlew writes, runs and reads back OpenFOAM cases for these applications and models:
- **Applications:** simpleFoam, pimpleFoam, pisoFoam, icoFoam, potentialFoam, buoyant(Boussinesq)Simple/PimpleFoam, rhoSimpleFoam, rhoPimpleFoam, rhoCentralFoam, chtMultiRegion(Simple)Foam.
- **Turbulence:** RANS, LES and DES.
- **Zones and sources:** MRF, porous zones, actuator disks, momentum and energy sources.
- **Physics:** fvDOM and P1 radiation, atmospheric boundary layers, passive scalars.
- **Tools:** snappyHexMesh, the function objects listed in the README, and case-file overrides.

Any case file can already be replaced by hand on the OpenFOAM page (Case Files), and custom
stages can run any OpenFOAM application. Neither gives Curlew's setup pages a model, though.
The list below is what the installed OpenFOAM (ESI v2606) ships and Curlew has no setup pages
for. Within each area, the features are ordered roughly by how often CFD work needs them.

## Solvers (applications)

| Area | OpenFOAM applications | What it would add |
|---|---|---|
| Multiphase, free surface (VOF) | interFoam, interIsoFoam, multiphaseInterFoam, compressibleInterFoam, potentialFreeSurfaceFoam, twoLiquidMixingFoam | Free surfaces: sloshing, dam break, ship hulls, filling, wave tanks |
| Phase change, cavitation | interPhaseChangeFoam, cavitatingFoam, interCondensatingEvaporatingFoam | Cavitation in pumps and injectors, condensation and boiling |
| Euler–Euler multiphase | twoPhaseEulerFoam, multiphaseEulerFoam, reactingTwoPhaseEulerFoam, reactingMultiphaseEulerFoam, driftFluxFoam | Bubble columns, fluidised beds, boiling flows, settling slurries |
| Lagrangian particles and sprays | DPMFoam, MPPICInterFoam, kinematicParcelFoam, reactingParcelFoam, sprayFoam, coalChemistryFoam, simpleCoalParcelFoam | Particle tracking, sprays, erosion, coal combustion |
| Combustion and species | reactingFoam, XiFoam, PDRFoam, fireFoam, chemFoam, coldEngineFoam | Multi-species transport, chemistry, premixed and non-premixed flames, fires, explosions |
| Adjoint optimisation | adjointOptimisationFoam, adjointShapeOptimizationFoam | Shape and topology optimisation from drag or pressure-drop sensitivities |
| Solid mechanics | solidDisplacementFoam, solidEquilibriumDisplacementFoam | Thermal stress in the solids of conjugate cases |
| Solid-only heat conduction | solidFoam, thermoFoam | Transient conduction without a fluid |
| Acoustics | acousticFoam, plus the Curle and proudmanAcousticPower function objects | Acoustic propagation, noise sources |
| Electromagnetics | mhdFoam, electrostaticFoam, magneticFoam | Liquid-metal flows, electrostatics |
| Finite area (thin films) | liquidFilmFoam, surfactantFoam | Liquid films on walls |
| Other | nonNewtonianIcoFoam, sonicFoam, rhoPimpleAdiabaticFoam, shallowWaterFoam, laplacianFoam, scalarTransportFoam, boundaryFoam, dnsFoam, dsmcFoam, molecularDynamics, financialFoam | Specialised solvers; DNS was deliberately left out |

## Mesh and motion

- **Dynamic meshes:**
  - cyclicAMI sliding interfaces, for transient rotor–stator, fans and turbomachinery. Curlew has steady MRF only.
  - Overset meshes (overPimpleDyMFoam).
  - Mesh morphing and 6-DoF rigid-body motion (floating bodies, valves).
  - Adaptive refinement (dynamicRefineFvMesh).
  - moveMesh.
- **Coupled boundaries:** mergeMeshes and stitchMesh. (Periodic cyclicAMI patches, and fan, porous-jump and thin-wall baffles through createBaffles, are now set up by Curlew.)
- **Mesh generators and editors:** foamyHexMesh, PDRblockMesh, extrudeMesh / extrude2DMesh, refineMesh, mirrorMesh, splitMeshRegions, subsetMesh, transformPoints, renumberMesh, and topoSet / setsToZones as a cell-set editor.

## Pre-processing

- mapFields / mapFieldsPar: start from a solution on another mesh.
- setFields / setExprFields beyond Curlew's box, sphere and cylinder patching.
- applyBoundaryLayer.
- boxTurb / createBoxTurb.
- viewFactorsGen, for surface-to-surface radiation with the viewFactor model.
- changeDictionary.

## Boundary conditions not mapped

- **Inflow profiles:**
  - Synthetic turbulent inflow for LES (turbulentDFSEMInlet, turbulentDigitalFilterInlet, turbulentInlet).
  - Profiles from files (timeVaryingMappedFixedValue, fixedProfile).
  - uniformInletOutlet.
- **Outlets and inlets:**
  - Non-reflecting outlets (waveTransmissive, advective).
  - Volumetric flow inlets (flowRateInletVelocity with a volumetric rate).
  - prghTotalPressure, and totalPressure with a fixed flow direction.
- **Walls:** sand-grain rough walls (nutkRoughWallFunction with Ks); Curlew writes only the atmospheric z₀ form.
- **Fans:** fan curves at inlets and outlets (fanPressure). The fan jump inside the domain is covered by the baffle settings.

## Physical models

- **Thermophysics:**
  - Temperature-dependent properties (polynomial, janaf, Sutherland thermo).
  - Real gases (Peng–Robinson, a general cubic equation of state).
  - Temperature-dependent solids.
  - Multi-species mixtures.
- **Radiation:** the viewFactor (S2S) and solarLoad models, multi-band absorption and emission, opaqueSolid.
- **Turbulence:**
  - Reynolds-stress models (LRR, SSG).
  - Transition models (kOmegaSSTLM, kkLOmega).
  - v2f.
  - kOmegaSSTSAS.
  - Further LES models (dynamicLagrangian, DeardorffDiffStress).
- **fvOptions and constraints:**
  - rotorDisk: a blade-element rotor model, a better wind-turbine model than actuator disks.
  - radialActuationDiskSource.
  - buoyancyForce / buoyancyEnergy.
  - effectivenessHeatExchangerSource.
  - solidificationMeltingSource.
  - directionalPressureGradientExplicitSource.
  - fixedTemperatureConstraint.
  - acousticDampingSource.
  - jouleHeatingSource.
  - tabulatedAccelerationSource.

## Function objects and post-processing

- **Field functions:** streamLine and wallBoundedStreamLine (Curlew traces pathlines itself), plus histogram, fluxSummary, heatTransferCoeff, age, comfort (PMV/PPD), PecletNo, enstrophy, nearWallFields, DMD and extractEulerianParticles.
- **Sampling and visualisation:** line and point sets (`sets`), runTimePostProcessing images, foamToEnsight and foamToVTK conversion.
- **Coupling:** externalCoupled co-simulation.

## Running

- Multi-node MPI runs and job queues (Curlew runs on one Mac's cores), plus redistributePar and decomposition constraints.
- Restart management beyond "continue from latest time": time-directory selection and mapping.
