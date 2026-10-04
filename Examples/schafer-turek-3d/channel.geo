// Schäfer & Turek (1996) 3D-1Z: square channel 2.5 × 0.41 × 0.41 with a cylinder (D = 0.1) at x = 0.5.
// Mesh: gmsh channel.geo -setnumber hw 0.005 -setnumber hmax 0.022 -3 -format msh41 -o channel.msh

SetFactory("OpenCASCADE");
H = 0.41; L = 2.5; R = 0.05; cx = 0.5; cy = 0.2;
Box(1) = {0, 0, 0, L, H, H};
Cylinder(2) = {cx, cy, -0.1, 0, 0, H + 0.2, R};
BooleanDifference{ Volume{1}; Delete; }{ Volume{2}; Delete; }
eps = 1e-6;
inlet() = Surface In BoundingBox{-eps, -eps, -eps, eps, H+eps, H+eps};
outlet() = Surface In BoundingBox{L-eps, -eps, -eps, L+eps, H+eps, H+eps};
cyl() = Surface In BoundingBox{cx-R-eps, cy-R-eps, -eps, cx+R+eps, cy+R+eps, H+eps};
walls() = Surface{:};
walls() -= inlet(); walls() -= outlet(); walls() -= cyl();
Physical Surface("inlet") = inlet();
Physical Surface("outlet") = outlet();
Physical Surface("cylinder") = cyl();
Physical Surface("wall") = walls();
Physical Volume("fluid") = Volume{:};
Field[1] = Distance; Field[1].SurfacesList = {cyl()}; Field[1].Sampling = 200;
Field[2] = Threshold; Field[2].InField = 1; Field[2].SizeMin = hw; Field[2].SizeMax = hmax; Field[2].DistMin = 0.01; Field[2].DistMax = 0.3;
Background Field = 2;
Mesh.MeshSizeExtendFromBoundary = 0; Mesh.MeshSizeFromPoints = 0; Mesh.MeshSizeFromCurvature = 0;
Mesh.MeshSizeMax = hmax;
Mesh.Algorithm = 6; Mesh.Algorithm3D = 1; Mesh.Optimize = 1; Mesh.ElementOrder = 1;
