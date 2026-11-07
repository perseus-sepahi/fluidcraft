# Example: import a CAD model and solve it with OpenFOAM

`manifold.step` is a coolant distribution manifold drawn in millimetres. It has a 30 mm
header pipe, 300 mm long along +x, feeding three 15 mm branches that leave along −y.
`manifold.geo` is its source; `gmsh manifold.geo -0` regenerates the STEP file.

## In the app

1. **File › Import CAD for Analysis…** and choose `Examples/CAD/manifold.step`. This opens
   the module General CFD & CAD › CAD Import & Analysis.
2. Set these options:
   - File units **mm**
   - Type **Internal flow**
   - Flow direction **+x**
   - Inlet velocity **0.5 m/s**
   - Fluid **water-liquid**
   - Resolution **Coarse**
3. **Build Case**. Curlew meshes the model with Gmsh (tetrahedra and 12 prism layers) and
   finds the five openings: `inlet`, `outlet` (the far end of the header) and the branches
   `outlet_ymin`, `outlet_ymin2`, `outlet_ymin3`.
4. Close the header's far end so that it works as a manifold: on Boundary Conditions, change
   `outlet` to **Wall**.
5. Optional: under Pre & Post-Processing › Post-Processing, add a line sample from
   (0, 0, 0) to (0.3, 0, 0) and tick VTK export.
6. **Run Calculation** (⌘R). OpenFOAM's simpleFoam (k-ω SST) runs on the cores set in the
   OpenFOAM page. Results load back for contours and reports, and the line sample opens in
   the XY Plot.

## From the command line

```bash
curlew-cli cad-analysis Examples/CAD/manifold.step --type internal --axis 0 --speed 0.5 \
  --fluid water-liquid --unit mm --level coarse --wall outlet \
  --post-line 0,0,0:0.3,0,0 --vtk --run --backend openfoam --cores 4
```

## Result (OpenFOAM v2606, 60 886 cells, 30 s on 4 cores)

| Opening | Mass flow | Share |
|---|---|---|
| inlet | 0.3464 kg/s in | |
| branch 1 (x = 75 mm) | 0.1091 kg/s | 31.5 % |
| branch 2 (x = 150 mm) | 0.1160 kg/s | 33.5 % |
| branch 3 (x = 225 mm) | 0.1213 kg/s | 35.0 % |

The outflow balances the inflow. The flow split is the classic one for a dividing manifold:
the header slows down past each branch, so its static pressure recovers toward the closed end
(the line sample shows 564 → 628 Pa), and the last branch gets the most flow. The inlet
pressure is 568 Pa.

The same model is also built in as the **Coolant manifold** sample (File › CAD Samples),
drawn in metres. `manifold-result.curlew` holds the solved case: open it with File › Open
Case to see the contours, reports and XY plot straight away.
