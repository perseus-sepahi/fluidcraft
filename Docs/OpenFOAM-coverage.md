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

**Now set up by Curlew:**
- **Models:** the RAS models SST-SAS, SST Langtry–Menter, GEKO, LRR and SSG; the LES models sigma and DeardorffDiffStress; model coefficients; temperature-dependent and real-gas thermophysics (janaf, hPolynomial, polynomial transport, Peng–Robinson, icoPolynomial, perfectFluid).
- **Boundary conditions:** turbulentDFSEMInlet, timeVaryingMappedFixedValue, flowRateInletVelocity (volumetric), fanPressure, advective/waveTransmissive and nutkRoughWallFunction.
- **fvOptions:** rotorDisk, fixedTemperatureConstraint and velocityDampingConstraint.
- **Mesh:** adaptive refinement (dynamicRefineFvMesh).
- **Function objects:** exprField, histogram, heatTransferCoeff, age, comfort, LambVector, continuityError, momentum and a configurable fieldAverage.
- **Run control:** writeControl modes, the pressure reference point, the decomposition split and the GAMG and smoother details.
- **Post-processing:** a Python interface (`curlew_post`) for analysis OpenFOAM has no interface for.

Those items are no longer gaps; the rest of this list still is.

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
  - moveMesh.
- **Coupled boundaries:** mergeMeshes and stitchMesh. (Periodic cyclicAMI patches, and fan, porous-jump and thin-wall baffles through createBaffles, are now set up by Curlew.)
- **Mesh generators and editors:** foamyHexMesh, PDRblockMesh, extrudeMesh / extrude2DMesh, refineMesh, mirrorMesh, splitMeshRegions, subsetMesh, transformPoints, renumberMesh, and topoSet / setsToZones as a cell-set editor.

## Pre-processing

- mapFieldsPar (mapFields, setFields regions and applyBoundaryLayer are set up by Curlew).
- setExprFields beyond Curlew's box, sphere and cylinder patching.
- boxTurb / createBoxTurb.
- viewFactorsGen, for surface-to-surface radiation with the viewFactor model.
- changeDictionary.

## Boundary conditions not mapped

- **Inflow profiles:** turbulentDigitalFilterInlet, turbulentInlet, fixedProfile and uniformInletOutlet (DFSEM and mapped profiles are covered).
- **Outlets and inlets:** totalPressure with a fixed flow direction (pressureDirectedInletVelocity).

## Physical models

- **Thermophysics:**
  - Tabulated properties (tabulatedTransport, hTabulatedThermo, icoTabulated).
  - Temperature-dependent solids.
  - Multi-species mixtures.
- **Radiation:** the viewFactor (S2S) and solarLoad models, multi-band absorption and emission, opaqueSolid.
- **Turbulence:** EBRSM, kEpsilonPhitF (v2f-type) and the LES dynamicLagrangian model.
- **fvOptions and constraints:**
  - radialActuationDiskSource.
  - buoyancyForce / buoyancyEnergy.
  - effectivenessHeatExchangerSource.
  - solidificationMeltingSource.
  - directionalPressureGradientExplicitSource.
  - acousticDampingSource.
  - jouleHeatingSource.
  - tabulatedAccelerationSource.

## Function objects and post-processing

- **Field functions:** wallBoundedStreamLine, fluxSummary (needs faceZones), nearWallFields, DMD (STDMD on transient snapshots) and extractEulerianParticles.
- **Visualisation:** runTimePostProcessing images (rendered scenes; the library is in the v2606 bundle). Line sets, iso-surfaces, streamlines, foamToVTK and foamToEnsight are set up by Curlew.
- **Coupling:** externalCoupled co-simulation.

## Running

- Multi-node MPI runs and job queues (Curlew runs on one Mac's cores), plus redistributePar and decomposition constraints.
- Restart management beyond "continue from latest time": time-directory selection and mapping.
