#!/usr/bin/env bash
# =============================================================================
# GROMACS MD SIMULATION PIPELINE
# Author      : Ritika Bist
# Description : Single-script GROMACS MD pipeline for Linux/HPC
#               Runs pdb2gmx → solvation → ions → EM → NVT → NPT → MD → analysis
# Usage       : bash gromacs_md_pipeline.sh
# Edit        : Only change PROTEIN below to match your input PDB (no extension)
# =============================================================================

set -euo pipefail

# =============================================================================
# USER CONFIGURATION — only section you need to edit
# =============================================================================

PROTEIN="pdb_file" #without extension
GMX="gmx_mpi"

# =============================================================================
# DIRECTORY LAYOUT
# All outputs are separated by stage. Nothing dumps into root.
#
# project/
# ├── input/           ← your PDB goes here
# ├── mdp/             ← all .mdp files go here
# ├── output/
# │   ├── topology/    ← topol.top, .itp files, processed.gro
# │   ├── em/          ← energy minimization
# │   ├── nvt/         ← NVT equilibration
# │   ├── npt/         ← NPT equilibration
# │   ├── md/          ← production MD trajectory
# │   └── analysis/    ← RMSD, Rg, and other analysis outputs
# └── logs/            ← per-stage stdout + stderr logs
# =============================================================================

INPUT_DIR="input"
MDP_DIR="mdp"
TOPO_DIR="output/topology"
EM_DIR="output/em"
NVT_DIR="output/nvt"
NPT_DIR="output/npt"
MD_DIR="output/md"
ANALYSIS_DIR="output/analysis"
LOG_DIR="logs"

# =============================================================================
# DERIVED FILENAMES — do not edit below unless you know what you are doing
# =============================================================================

INPUT_PDB="${INPUT_DIR}/${PROTEIN}.pdb"
PROCESSED="${TOPO_DIR}/${PROTEIN}_processed.gro"
NEWBOX="${TOPO_DIR}/${PROTEIN}_newbox.gro"
SOLV="${TOPO_DIR}/${PROTEIN}_solv.gro"
SOLV_IONS="${TOPO_DIR}/${PROTEIN}_solv_ions.gro"
TOPOL="${TOPO_DIR}/topol.top"

IONS_MDP="${MDP_DIR}/ions.mdp"
MINIM_MDP="${MDP_DIR}/minim.mdp"
NVT_MDP="${MDP_DIR}/nvt.mdp"
NPT_MDP="${MDP_DIR}/npt.mdp"
MD_MDP="${MDP_DIR}/md.mdp"

# =============================================================================
# UTILITIES
# =============================================================================

# Print a timestamped banner for each major stage
stage_banner() {
    echo ""
    echo "============================================================"
    echo "  STAGE $1 — $2"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
}

# Hard-stop if a required file is missing or empty
check_file() {
    if [[ ! -f "$1" || ! -s "$1" ]]; then
        echo "ERROR: Required file missing or empty: $1"
        exit 1
    fi
}

# grompp wrapper: first attempt without -maxwarn; retries with -maxwarn 1
# GROMACS sometimes throws non-fatal warnings that block preprocessing.
# Using -maxwarn 1 selectively avoids silencing everything globally.
run_grompp() {
    if ! "$GMX" grompp "$@" 2>/dev/null; then
        echo "  WARNING: grompp failed without -maxwarn. Retrying with -maxwarn 1 ..."
        "$GMX" grompp "$@" -maxwarn 1
    fi
}

# =============================================================================
# SETUP — create directory structure before anything runs
# =============================================================================

echo "Setting up directory structure ..."
mkdir -p "$INPUT_DIR" "$MDP_DIR" \
         "$TOPO_DIR" "$EM_DIR" "$NVT_DIR" "$NPT_DIR" "$MD_DIR" "$ANALYSIS_DIR" \
         "$LOG_DIR"

# =============================================================================
# PRE-FLIGHT CHECKS — verify all required input files exist before starting
# Fail fast here so you don't waste 20 minutes only to hit a missing .mdp
# =============================================================================

echo "Running pre-flight checks ..."
for f in "$INPUT_PDB" "$IONS_MDP" "$MINIM_MDP" "$NVT_MDP" "$NPT_MDP" "$MD_MDP"; do
    check_file "$f"
done
echo "All required input files found. Starting pipeline."

# =============================================================================
# STAGE 1 — pdb2gmx
# Assigns force field and builds the molecular topology.
# Interactive selections piped in: 13 = CHARMM36, 1 = TIP3P water model
# Outputs: processed .gro file + topol.top
# =============================================================================

stage_banner 1 "pdb2gmx — Force field assignment and topology"

printf "13\n1\n" | "$GMX" pdb2gmx \
    -f "$INPUT_PDB" \
    -o "$PROCESSED" \
    -p "$TOPOL" \
    >> "${LOG_DIR}/stage1_pdb2gmx.log" 2>&1

check_file "$PROCESSED"
check_file "$TOPOL"
echo "Stage 1 done → $PROCESSED"

# =============================================================================
# STAGE 2 — editconf
# Defines the simulation box: cubic, 1.0 nm padding around the protein.
# -c centers the protein in the box.
# =============================================================================

stage_banner 2 "editconf — Simulation box construction"

"$GMX" editconf \
    -f "$PROCESSED" \
    -o "$NEWBOX" \
    -c -d 1.0 -bt cubic \
    >> "${LOG_DIR}/stage2_editconf.log" 2>&1

check_file "$NEWBOX"
echo "Stage 2 done → $NEWBOX"

# =============================================================================
# STAGE 3 — solvate
# Fills the box with SPC/E water (spc216.gro is GROMACS built-in).
# Automatically updates topol.top with solvent molecule count.
# =============================================================================

stage_banner 3 "solvate — Filling box with water"

"$GMX" solvate \
    -cp "$NEWBOX" \
    -cs spc216.gro \
    -o "$SOLV" \
    -p "$TOPOL" \
    >> "${LOG_DIR}/stage3_solvate.log" 2>&1

check_file "$SOLV"
echo "Stage 3 done → $SOLV"

# =============================================================================
# STAGE 4 — grompp + genion
# Prepares a dummy .tpr for ion insertion, then replaces water molecules
# with NA+/CL- to neutralize the system charge.
# genion selection: 13 = SOL group (solvent)
# =============================================================================

stage_banner 4 "genion — Adding neutralizing ions"

run_grompp \
    -f "$IONS_MDP" \
    -c "$SOLV" \
    -p "$TOPOL" \
    -o "${TOPO_DIR}/ions.tpr" \
    >> "${LOG_DIR}/stage4_grompp_ions.log" 2>&1

check_file "${TOPO_DIR}/ions.tpr"

echo "13" | "$GMX" genion \
    -s "${TOPO_DIR}/ions.tpr" \
    -o "$SOLV_IONS" \
    -p "$TOPOL" \
    -pname NA -nname CL -neutral \
    >> "${LOG_DIR}/stage4_genion.log" 2>&1

check_file "$SOLV_IONS"
echo "Stage 4 done → $SOLV_IONS"

# =============================================================================
# STAGE 5 — Energy minimization
# Relaxes steric clashes introduced during solvation/ion placement.
# Uses steepest descent as specified in minim.mdp.
# All EM output files land in output/em/
# =============================================================================

stage_banner 5 "Energy minimization"

run_grompp \
    -f "$MINIM_MDP" \
    -c "$SOLV_IONS" \
    -p "$TOPOL" \
    -o "${EM_DIR}/em.tpr" \
    >> "${LOG_DIR}/stage5_grompp_em.log" 2>&1

"$GMX" mdrun -v -deffnm "${EM_DIR}/em" \
    >> "${LOG_DIR}/stage5_mdrun_em.log" 2>&1

for f in "${EM_DIR}/em.edr" "${EM_DIR}/em.gro" "${EM_DIR}/em.log" "${EM_DIR}/em.tpr"; do
    check_file "$f"
done
echo "Stage 5 done → ${EM_DIR}/em.gro"

# =============================================================================
# STAGE 6 — NVT equilibration
# Equilibrates temperature at constant volume with position restraints.
# -r flag passes restraint reference coordinates (same as starting structure).
# =============================================================================

stage_banner 6 "NVT equilibration — Temperature"

run_grompp \
    -f "$NVT_MDP" \
    -c "${EM_DIR}/em.gro" \
    -r "${EM_DIR}/em.gro" \
    -p "$TOPOL" \
    -o "${NVT_DIR}/nvt.tpr" \
    >> "${LOG_DIR}/stage6_grompp_nvt.log" 2>&1

"$GMX" mdrun -deffnm "${NVT_DIR}/nvt" \
    >> "${LOG_DIR}/stage6_mdrun_nvt.log" 2>&1

check_file "${NVT_DIR}/nvt.cpt"
check_file "${NVT_DIR}/nvt.gro"
echo "Stage 6 done → ${NVT_DIR}/nvt.gro"

# =============================================================================
# STAGE 7 — NPT equilibration
# Equilibrates pressure at constant temperature with position restraints.
# -t passes the NVT checkpoint to continue velocities and thermostat state.
# =============================================================================

stage_banner 7 "NPT equilibration — Pressure"

run_grompp \
    -f "$NPT_MDP" \
    -c "${NVT_DIR}/nvt.gro" \
    -t "${NVT_DIR}/nvt.cpt" \
    -r "${NVT_DIR}/nvt.gro" \
    -p "$TOPOL" \
    -o "${NPT_DIR}/npt.tpr" \
    >> "${LOG_DIR}/stage7_grompp_npt.log" 2>&1

"$GMX" mdrun -deffnm "${NPT_DIR}/npt" \
    >> "${LOG_DIR}/stage7_mdrun_npt.log" 2>&1

for f in "${NPT_DIR}/npt.cpt" "${NPT_DIR}/npt.edr" "${NPT_DIR}/npt.gro"; do
    check_file "$f"
done
echo "Stage 7 done → ${NPT_DIR}/npt.gro"

# =============================================================================
# STAGE 8 — Production MD
# Unconstrained simulation. No position restraints.
# -t continues from NPT checkpoint (preserves thermostat/barostat state).
# Output lands in output/md/
# =============================================================================

stage_banner 8 "Production MD"

run_grompp \
    -f "$MD_MDP" \
    -c "${NPT_DIR}/npt.gro" \
    -t "${NPT_DIR}/npt.cpt" \
    -p "$TOPOL" \
    -o "${MD_DIR}/md_0_10.tpr" \
    >> "${LOG_DIR}/stage8_grompp_md.log" 2>&1

"$GMX" mdrun -deffnm "${MD_DIR}/md_0_10" \
    >> "${LOG_DIR}/stage8_mdrun_md.log" 2>&1

check_file "${MD_DIR}/md_0_10.xtc"
check_file "${MD_DIR}/md_0_10.gro"
echo "Stage 8 done → ${MD_DIR}/md_0_10.xtc"

echo ""
echo "Last 30 lines of production MD log:"
tail -n 30 "${MD_DIR}/md_0_10.log"

# =============================================================================
# STAGE 9 — trjconv: PBC correction
# Fixes periodic boundary artifacts in the trajectory.
# Protein is re-centered; whole system is written out.
# Selection: 1 (Protein, center) → 0 (System, output)
# =============================================================================

stage_banner 9 "trjconv — PBC correction"

printf "1\n0\n" | "$GMX" trjconv \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10.xtc" \
    -o "${MD_DIR}/md_0_10_noPBC.xtc" \
    -pbc mol -center \
    >> "${LOG_DIR}/stage9_trjconv.log" 2>&1

check_file "${MD_DIR}/md_0_10_noPBC.xtc"
echo "Stage 9 done → ${MD_DIR}/md_0_10_noPBC.xtc"

# =============================================================================
# STAGE 10 — RMSD (backbone)
# Measures backbone structural deviation relative to the starting structure.
# Selection: 4 (Backbone) for both fitting and RMSD calculation.
# Output: analysis/rmsd_backbone.xvg — plot with xmgrace or Python
# =============================================================================

stage_banner 10 "RMSD — Backbone"

printf "4\n4\n" | "$GMX" rms \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10_noPBC.xtc" \
    -o "${ANALYSIS_DIR}/rmsd_backbone.xvg" \
    >> "${LOG_DIR}/stage10_rmsd.log" 2>&1

check_file "${ANALYSIS_DIR}/rmsd_backbone.xvg"
echo "Stage 10 done → ${ANALYSIS_DIR}/rmsd_backbone.xvg"

# =============================================================================
# STAGE 11 — Radius of gyration
# Tracks overall protein compactness over the trajectory.
# Selection: 1 (Protein)
# Output: analysis/gyrate.xvg
# =============================================================================

stage_banner 11 "Radius of gyration"

echo "1" | "$GMX" gyrate \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10_noPBC.xtc" \
    -o "${ANALYSIS_DIR}/gyrate.xvg" \
    >> "${LOG_DIR}/stage11_gyrate.log" 2>&1

check_file "${ANALYSIS_DIR}/gyrate.xvg"
echo "Stage 11 done → ${ANALYSIS_DIR}/gyrate.xvg"

# =============================================================================
# PIPELINE SUMMARY
# =============================================================================

echo ""
echo "================================================================="
echo "  PIPELINE COMPLETE"
echo "  Protein   : $PROTEIN"
echo "  Completed : $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo ""
echo "Key output files:"
ls -lh \
    "$PROCESSED" \
    "$SOLV_IONS" \
    "${EM_DIR}/em.gro" \
    "${NVT_DIR}/nvt.gro" \
    "${NPT_DIR}/npt.gro" \
    "${MD_DIR}/md_0_10.gro" \
    "${MD_DIR}/md_0_10.xtc" \
    "${MD_DIR}/md_0_10_noPBC.xtc" \
    "${ANALYSIS_DIR}/rmsd_backbone.xvg" \
    "${ANALYSIS_DIR}/gyrate.xvg" \
    2>/dev/null || true
echo ""
echo "Logs are in: ${LOG_DIR}/"
ls -1 "${LOG_DIR}/"
echo "================================================================="
