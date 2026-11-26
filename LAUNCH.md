# FluidCraft launch record

## 1.0 — 25 November 2026

**Name check** (25 Nov 2026). FluidCraft replaced Curlew; "Fluxion" was rejected first (live US
class-9 filing FLUXION 79439387 for industrial software, and an existing Mac App Store app).
Searched for "FluidCraft":
- USPTO trademark search: no marks.
- WIPO Global Brand Database (EU, UK, Canada and ~90 national registers): no marks.
- App Store (US, Canada; iPhone, iPad and Mac): no app (skill `name_check.py`).
- GitHub: two **empty** repositories reserve the name (`zhilongwei/fluidcraft`, created
  5 Oct 2026, "Craft your own fluid solvers"; `tinted-software/fluidcraft`, 2024); no code,
  no releases. Minecraft mods "Fluid Crafting" / "AE2 Fluid Crafting" are a different name and field.
- Web search: nothing else answers to the name.
- Domains: fluidcraft.app and fluidcraft.dev unregistered; fluidcraft.com parked for sale.
- Not checked: App Store Connect record (FluidCraft is not on the App Store), Google Play (no Android build).
A clean result means no conflict was found in these places, not that the name is guaranteed free.

**Editions**
| OS | Edition | Version / build | Where |
|---|---|---|---|
| macOS 15+, Apple silicon | Direct (Developer ID, hardened runtime, notarized, stapled) | 1.0 (19) | GitHub release `v1.0`: `FluidCraft.dmg` |

No App Store edition: Mac App Store apps must use App Sandbox, and a sandboxed FluidCraft could
not start OpenFOAM, mount its disk image or run Homebrew installs. No paid features, so no
Stripe, licence keys or discount codes.

**Licence**: GNU GPL v3 (`LICENSE`); `THIRD-PARTY-NOTICES.md` lists the programs FluidCraft runs
but does not include (OpenFOAM, Gmsh, ParaView, Python, PyTorch, Homebrew) and the trademarks.

**Links**
- Repository: https://github.com/perseus-sepahi/fluidcraft (public, `main`)
- Release: https://github.com/perseus-sepahi/fluidcraft/releases/tag/v1.0
- Website: https://perseus-sepahi.github.io/software/fluidcraft/ (privacy and support pages under it)

**History**: one 6 Nov 2026 commit message carried a co-author trailer; it was removed before
the first push (`git filter-branch --msg-filter`), trees unchanged. Tag `pre-openfoam-only-2026-11-24`
keeps the former built-in solvers.
