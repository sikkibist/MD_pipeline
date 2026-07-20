# Automated GROMACS Pipeline for PHT1 Molecular Dynamics Simulations

A reproducible, batch-mode molecular dynamics pipeline built to evaluate structural stability differences between wild-type and SNP mutant variants of PHT1 phosphate transporter proteins. Developed during a Summer Training project at the Division of Agricultural Bioinformatics, ICAR-IASRI, under Dr. Anshuman Singh.

## Background

PHT1 transporters mediate phosphate uptake in plant roots, and their structural integrity directly affects phosphorus use efficiency (PUE). This pipeline was built to systematically test whether specific SNP-derived amino acid substitutions stabilize or destabilize the PHT1 fold — providing a computational shortlist of variants worth prioritizing for experimental validation and marker-assisted breeding.

## Scope

- **33 protein systems** across 3 crop species: *Lupinus albus* (white lupin), *Oryza sativa* (rice), *Brassica napus* (canola) — wild-type plus SNP mutants for each
- **10 ns all-atom MD simulation** per system via GROMACS
- **Force fields:** CHARMM36 / TIP3P water (*Lupinus albus*, *Oryza sativa*); GROMOS96 53a6 / SPC water (*Brassica napus*)
- **Metrics:** backbone RMSD and radius of gyration (Rg) → 66 trajectories analyzed
- Run on the ASHOKA HPC cluster, ICAR-IASRI

## Pipeline structure

- **`gromacs_md_pipeline.sh`** — core 11-stage GROMACS workflow for a single protein system (topology generation through production MD). Every stage is checked by a `check_file()` function that verifies output existence and non-zero size before proceeding. A `run_grompp()` wrapper automatically retries failed `grompp` calls with `-maxwarn 1` to handle minor non-fatal topology warnings.
- **`run_all.sh`** — batch wrapper that iterates over every protein subdirectory and runs its copy of the pipeline sequentially, with no manual intervention between systems.
- **Directory convention:** each protein system lives in its own subdirectory containing its input PDB file, all five `.mdp` parameter files (`ions`, `minim`, `nvt`, `npt`, `md`), and a copy of `gromacs_md_pipeline.sh` with the `PROTEIN` variable set to that system's filename.

## Reproducibility

- MDP parameter files are version-controlled and identical across all protein systems — only the input PDB differs between runs
- `check_file()` halts execution at any stage where expected output is missing or empty, preventing silent failures from propagating downstream
- `set -e` in both scripts enforces immediate termination on any unhandled error
- Validated across all 33 protein systems with consistent output and zero stage failures

## Key findings

- SNP effects span the full range, from strongly destabilizing (BnPHT1_3_3 Mutant A: RMSD ~45–50% above wild-type) to strongly stabilizing (LaPHT1;2 F40L: RMSD ~0.40–0.50 nm below wild-type) — no single directional rule applies
- Three independent protein–SNP combinations produced reproducible, converged RMSD plateaus at or below wild-type, flagging them as candidate stabilizing variants for further validation
- Position 156 shows conserved structural sensitivity across LaPHT1 paralogues
- A subset of Brassica mutants show a distinct "over-compaction" signature (Rg minima well below wild-type) not seen in wild-type or stabilizing variants

## Tools

GROMACS · Bash · CHARMM36 / GROMOS96 53a6 force fields

## Acknowledgment

Developed during Summer Training at the Division of Agricultural Bioinformatics, ICAR–Indian Agricultural Statistics Research Institute (ICAR-IASRI), New Delhi, under the guidance of Dr. Anshuman Singh, Senior Scientist.

## Author
**Ritika Bist**
**M.Sc Bioinformatics**
