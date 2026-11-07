// Coolant distribution manifold (millimetres): a 30 mm header pipe, 300 mm long along +x,
// feeding three 15 mm branches that leave along -y. Run `gmsh manifold.geo -0` to write
// manifold.step (exact OpenCASCADE geometry), the file Curlew imports.
SetFactory("OpenCASCADE");
Cylinder(1) = {0, 0, 0, 300, 0, 0, 15};
Cylinder(2) = {75, 0, 0, 0, -120, 0, 7.5};
Cylinder(3) = {150, 0, 0, 0, -120, 0, 7.5};
Cylinder(4) = {225, 0, 0, 0, -120, 0, 7.5};
BooleanUnion{ Volume{1}; Delete; }{ Volume{2:4}; Delete; }
Save "manifold.step";
