# GROMACS MD Simulation Pipeline — any file.pdb

> Single-script GROMACS pipeline for protein molecular dynamics.
> Designed for Linux workstations and HPC clusters.

---

## System (used this pipeline on:)

| Item | Value |
|------|-------|
| Protein | ZmPHT1_1_mutant_H |
| Force field | CHARMM36 |
| Water model | TIP3P |
| Box type | Cubic, 1.0 nm padding |
| Ions | Na⁺ / Cl⁻ (neutralizing) |
| Simulation length | Defined in `mdp/md.mdp` |

---

## Directory Structure

```
project/
├── input/                    # Input PDB file(s)
├── mdp/                      # All MDP parameter files
│   ├── ions.mdp
│   ├── minim.mdp
│   ├── nvt.mdp
│   ├── npt.mdp
│   └── md.mdp
├── output/
│   ├── topology/             # topol.top, processed.gro, solvated structures
│   ├── em/                   # Energy minimization outputs
│   ├── nvt/                  # NVT equilibration outputs
│   ├── npt/                  # NPT equilibration outputs
│   ├── md/                   # Production MD trajectory and coordinates
│   └── analysis/             # RMSD, radius of gyration, other analysis
├── logs/                     # Per-stage stdout + stderr logs
├── gromacs_md_pipeline.sh    # Main pipeline script
├── .gitignore
└── README.md
```

---

## Requirements

- GROMACS (built with MPI: `gmx_mpi`). Tested with GROMACS 2021–2024.
- Bash ≥ 4.0
- Standard HPC Linux environment (CentOS 7, Ubuntu 20.04+)

To check your GROMACS version:
```bash
gmx_mpi --version
```

---

## Usage

### 1. Place your input files

```bash
cp YourProtein.pdb input/
cp *.mdp mdp/
```

### 2. Edit the protein name in the script

Open `gromacs_md_pipeline.sh` and change only this line:

```bash
PROTEIN="YourProtein"
```

### 3. Run

```bash
chmod +x gromacs_md_pipeline.sh
bash gromacs_md_pipeline.sh
```

### 4. On HPC (SLURM example)

```bash
sbatch run_gromacs.slurm
```

A minimal SLURM script:

```bash
#!/bin/bash
#SBATCH --job-name=md_zmPHT1
#SBATCH --ntasks=16
#SBATCH --time=48:00:00
#SBATCH --mem=32G
#SBATCH --output=logs/slurm_%j.out

module load gromacs/2023
bash gromacs_md_pipeline.sh
```

---

## Pipeline Stages

| Stage | Tool | Description |
|-------|------|-------------|
| 1 | `pdb2gmx` | Force field assignment, topology generation |
| 2 | `editconf` | Cubic simulation box, 1 nm padding |
| 3 | `solvate` | TIP3P water solvation |
| 4 | `genion` | Neutralizing Na⁺/Cl⁻ ions |
| 5 | `mdrun` | Energy minimization (steepest descent) |
| 6 | `mdrun` | NVT equilibration (temperature, position-restrained) |
| 7 | `mdrun` | NPT equilibration (pressure + temperature, position-restrained) |
| 8 | `mdrun` | Production MD |
| 9 | `trjconv` | PBC artifact correction |
| 10 | `gmx rms` | Backbone RMSD |
| 11 | `gmx gyrate` | Radius of gyration |

---

## Outputs

| File | Location | Description |
|------|----------|-------------|
| `topol.top` | `output/topology/` | Full system topology |
| `em.gro` | `output/em/` | Energy-minimized structure |
| `nvt.gro` | `output/nvt/` | Temperature-equilibrated structure |
| `npt.gro` | `output/npt/` | Pressure-equilibrated structure |
| `md_0_10.xtc` | `output/md/` | Raw production trajectory |
| `md_0_10_noPBC.xtc` | `output/md/` | PBC-corrected trajectory |
| `rmsd_backbone.xvg` | `output/analysis/` | Backbone RMSD over time |
| `gyrate.xvg` | `output/analysis/` | Radius of gyration over time |

---

## Analyzing Outputs

Plot `.xvg` files with Grace:
```bash
xmgrace output/analysis/rmsd_backbone.xvg
```

Or with Python (matplotlib):
```python
import numpy as np
import matplotlib.pyplot as plt

data = np.loadtxt("output/analysis/rmsd_backbone.xvg", comments=["#", "@"])
plt.plot(data[:, 0] / 1000, data[:, 1] * 10)   # ps→ns, nm→Å
plt.xlabel("Time (ns)")
plt.ylabel("RMSD (Å)")
plt.title("Backbone RMSD — ZmPHT1_1 Mutant H")
plt.savefig("output/analysis/rmsd_backbone.png", dpi=300)
```

---

## Logs

Each stage writes its own log to `logs/`:

```
logs/
├── stage1_pdb2gmx.log
├── stage2_editconf.log
├── stage3_solvate.log
├── stage4_grompp_ions.log
├── stage4_genion.log
├── stage5_grompp_em.log
├── stage5_mdrun_em.log
├── stage6_grompp_nvt.log
├── stage6_mdrun_nvt.log
├── stage7_grompp_npt.log
├── stage7_mdrun_npt.log
├── stage8_grompp_md.log
├── stage8_mdrun_md.log
├── stage9_trjconv.log
├── stage10_rmsd.log
└── stage11_gyrate.log
```

If a stage fails, check the corresponding log directly — no hunting through a single massive stdout file.

---

## Known Issues / Gotchas

- **CHARMM36 and TIP3P**: The interactive selections (13, 1) passed to `pdb2gmx` are GROMACS-version-sensitive. Verify they match your installation's menu.
- **genion SOL group**: Selection 13 (SOL) may shift depending on your system composition. Check your genion log if ion insertion fails.
- **-maxwarn 1**: Used only as a fallback. If grompp keeps triggering it, inspect the actual warning in the log — don't suppress blindly.
- **PBC correction**: `trjconv` selections (Protein center, System output) assume a standard protein-in-water system. Adjust if your system has membrane or ligand groups.
- **Large trajectories**: `.xtc` and `.trr` files are not tracked by git. Archive them on institutional storage or Zenodo.

---

## Citation

If you use or adapt this pipeline, cite:
- GROMACS: Abraham et al., *SoftwareX* 1–2 (2015), 19–25.
- CHARMM36: Best et al., *J. Chem. Theory Comput.* 8 (2012), 3257–3273.
- TIP3P: Jorgensen et al., *J. Chem. Phys.* 79 (1983), 926.

---

## Author

Ritika Bist  
M.Sc. Bioinformatics
