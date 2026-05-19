#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GROMACS MD SIMULATION PIPELINE
# Author      : Ritika Bist
# Description : Single-script GROMACS MD pipeline for Linux/HPC
# Usage       : bash gromacs_md_pipeline.sh
# Edit        : Only change PROTEIN below to match your input PDB (no extension)
# =============================================================================

PROTEIN="ZmPHT1_1_mutant_H" #no extension
GMX="gmx_mpi"

# --- File names from PROTEIN ---
INPUT_PDB="${PROTEIN}.pdb"
PROCESSED="${PROTEIN}_processed.gro"
NEWBOX="${PROTEIN}_newbox.gro"
SOLV="${PROTEIN}_solv.gro"
SOLV_IONS="${PROTEIN}_solv_ions.gro"

# --- MDP files (should be in current directory) ---
IONS_MDP="ions.mdp"
MINIM_MDP="minim.mdp"
NVT_MDP="nvt.mdp"
NPT_MDP="npt.mdp"
MD_MDP="md.mdp"

# --- Output directories ---
# topol.top, posre.itp, and intermediate .gro files stay in root
# GROMACS resolves #include paths relative to where topol.top lives
# Only mdrun outputs and logs go into subdirectories
EM_DIR="output/em"
NVT_DIR="output/nvt"
NPT_DIR="output/npt"
MD_DIR="output/md"
ANALYSIS_DIR="output/analysis"
LOG_DIR="logs"

# =============================================================================
# UTILITIES
# =============================================================================

stage_banner() {
    echo ""
    echo "============================================================"
    echo "  STAGE $1 — $2"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
}

check_file() {
    if [[ ! -f "$1" || ! -s "$1" ]]; then
        echo "ERROR: Required file missing or empty: $1"
        exit 1
    fi
}

# grompp wrapper: tries without -maxwarn first, retries with -maxwarn 1 if needed
run_grompp() {
    if ! "$GMX" grompp "$@" 2>/dev/null; then
        echo "  WARNING: grompp failed without -maxwarn. Retrying with -maxwarn 1 ..."
        "$GMX" grompp "$@" -maxwarn 1
    fi
}

# =============================================================================
# SETUP
# =============================================================================

echo "Setting up directory structure ..."
mkdir -p "$EM_DIR" "$NVT_DIR" "$NPT_DIR" "$MD_DIR" "$ANALYSIS_DIR" "$LOG_DIR"

# =============================================================================
# PRE-FLIGHT
# =============================================================================

echo "Running pre-flight checks ..."
for f in "$INPUT_PDB" "$IONS_MDP" "$MINIM_MDP" "$NVT_MDP" "$NPT_MDP" "$MD_MDP"; do
    check_file "$f"
done
echo "All required input files found. Starting pipeline."

# =============================================================================
# STAGE 1 — pdb2gmx: assign force field and build topology
# Selection: 13 (CHARMM36) -> 1 (TIP3P)
# topol.top and posre.itp written to root — must stay here for include resolution
# =============================================================================

stage_banner 1 "pdb2gmx — Force field assignment and topology"

printf "13\n1\n" | "$GMX" pdb2gmx \
    -f "$INPUT_PDB" \
    -o "$PROCESSED" \
    -p topol.top \
    >> "${LOG_DIR}/stage1_pdb2gmx.log" 2>&1

check_file "$PROCESSED"
check_file "topol.top"
echo "Stage 1 done: $PROCESSED"

# =============================================================================
# STAGE 2 — editconf: create cubic simulation box
# =============================================================================

stage_banner 2 "editconf — Simulation box construction"

"$GMX" editconf \
    -f "$PROCESSED" \
    -o "$NEWBOX" \
    -c -d 1.0 -bt cubic \
    >> "${LOG_DIR}/stage2_editconf.log" 2>&1

check_file "$NEWBOX"
echo "Stage 2 done: $NEWBOX"

# =============================================================================
# STAGE 3 — solvate: fill box with water
# =============================================================================

stage_banner 3 "solvate — Filling box with water"

"$GMX" solvate \
    -cp "$NEWBOX" \
    -cs spc216.gro \
    -o "$SOLV" \
    -p topol.top \
    >> "${LOG_DIR}/stage3_solvate.log" 2>&1

check_file "$SOLV"
echo "Stage 3 done: $SOLV"

# =============================================================================
# STAGE 4 — grompp + genion: add neutralizing ions
# genion selection: 13 (SOL group)
# =============================================================================

stage_banner 4 "genion — Adding neutralizing ions"

run_grompp \
    -f "$IONS_MDP" \
    -c "$SOLV" \
    -p topol.top \
    -o ions.tpr \
    >> "${LOG_DIR}/stage4_grompp_ions.log" 2>&1

check_file "ions.tpr"

echo "13" | "$GMX" genion \
    -s ions.tpr \
    -o "$SOLV_IONS" \
    -p topol.top \
    -pname NA -nname CL -neutral \
    >> "${LOG_DIR}/stage4_genion.log" 2>&1

check_file "$SOLV_IONS"
echo "Stage 4 done: $SOLV_IONS"

# =============================================================================
# STAGE 5 — Energy minimization
# =============================================================================

stage_banner 5 "Energy minimization"

run_grompp \
    -f "$MINIM_MDP" \
    -c "$SOLV_IONS" \
    -p topol.top \
    -o "${EM_DIR}/em.tpr" \
    >> "${LOG_DIR}/stage5_grompp_em.log" 2>&1

"$GMX" mdrun -v -deffnm "${EM_DIR}/em" \
    >> "${LOG_DIR}/stage5_mdrun_em.log" 2>&1

for f in "${EM_DIR}/em.edr" "${EM_DIR}/em.gro" "${EM_DIR}/em.log" "${EM_DIR}/em.tpr"; do
    check_file "$f"
done
echo "Stage 5 done: energy minimization"

# =============================================================================
# STAGE 6 — NVT equilibration (temperature, position restrained)
# =============================================================================

stage_banner 6 "NVT equilibration — Temperature"

run_grompp \
    -f "$NVT_MDP" \
    -c "${EM_DIR}/em.gro" \
    -r "${EM_DIR}/em.gro" \
    -p topol.top \
    -o "${NVT_DIR}/nvt.tpr" \
    >> "${LOG_DIR}/stage6_grompp_nvt.log" 2>&1

"$GMX" mdrun -deffnm "${NVT_DIR}/nvt" \
    >> "${LOG_DIR}/stage6_mdrun_nvt.log" 2>&1

check_file "${NVT_DIR}/nvt.cpt"
check_file "${NVT_DIR}/nvt.gro"
echo "Stage 6 done: NVT equilibration"

# =============================================================================
# STAGE 7 — NPT equilibration (pressure + temperature, position restrained)
# =============================================================================

stage_banner 7 "NPT equilibration — Pressure"

run_grompp \
    -f "$NPT_MDP" \
    -c "${NVT_DIR}/nvt.gro" \
    -t "${NVT_DIR}/nvt.cpt" \
    -r "${NVT_DIR}/nvt.gro" \
    -p topol.top \
    -o "${NPT_DIR}/npt.tpr" \
    >> "${LOG_DIR}/stage7_grompp_npt.log" 2>&1

"$GMX" mdrun -deffnm "${NPT_DIR}/npt" \
    >> "${LOG_DIR}/stage7_mdrun_npt.log" 2>&1

for f in "${NPT_DIR}/npt.cpt" "${NPT_DIR}/npt.edr" "${NPT_DIR}/npt.gro"; do
    check_file "$f"
done
echo "Stage 7 done: NPT equilibration"

# =============================================================================
# STAGE 8 — Production MD
# =============================================================================

stage_banner 8 "Production MD"

run_grompp \
    -f "$MD_MDP" \
    -c "${NPT_DIR}/npt.gro" \
    -t "${NPT_DIR}/npt.cpt" \
    -p topol.top \
    -o "${MD_DIR}/md_0_10.tpr" \
    >> "${LOG_DIR}/stage8_grompp_md.log" 2>&1

"$GMX" mdrun -deffnm "${MD_DIR}/md_0_10" \
    >> "${LOG_DIR}/stage8_mdrun_md.log" 2>&1

check_file "${MD_DIR}/md_0_10.xtc"
check_file "${MD_DIR}/md_0_10.gro"
echo "Stage 8 done: production MD"
echo "Last 30 lines of MD log:"
tail -n 30 "${MD_DIR}/md_0_10.log"

# =============================================================================
# STAGE 9 — trjconv: fix PBC artifacts
# Selection: 1 (Protein, center) -> 0 (System, output)
# =============================================================================

stage_banner 9 "trjconv — PBC correction"

printf "1\n0\n" | "$GMX" trjconv \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10.xtc" \
    -o "${MD_DIR}/md_0_10_noPBC.xtc" \
    -pbc mol -center \
    >> "${LOG_DIR}/stage9_trjconv.log" 2>&1

check_file "${MD_DIR}/md_0_10_noPBC.xtc"
echo "Stage 9 done: PBC-corrected trajectory"

# =============================================================================
# STAGE 10 — RMSD (backbone)
# Selection: 4 (Backbone) -> 4 (Backbone)
# =============================================================================

stage_banner 10 "RMSD — Backbone"

printf "4\n4\n" | "$GMX" rms \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10_noPBC.xtc" \
    -o "${ANALYSIS_DIR}/rmsd_backbone.xvg" \
    >> "${LOG_DIR}/stage10_rmsd.log" 2>&1

check_file "${ANALYSIS_DIR}/rmsd_backbone.xvg"
echo "Stage 10 done: RMSD -> ${ANALYSIS_DIR}/rmsd_backbone.xvg"

# =============================================================================
# STAGE 11 — Radius of gyration
# Selection: 1 (Protein)
# =============================================================================

stage_banner 11 "Radius of gyration"

echo "1" | "$GMX" gyrate \
    -s "${MD_DIR}/md_0_10.tpr" \
    -f "${MD_DIR}/md_0_10_noPBC.xtc" \
    -o "${ANALYSIS_DIR}/gyrate.xvg" \
    >> "${LOG_DIR}/stage11_gyrate.log" 2>&1

check_file "${ANALYSIS_DIR}/gyrate.xvg"
echo "Stage 11 done: Gyration -> ${ANALYSIS_DIR}/gyrate.xvg"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "================================================================="
echo "  PIPELINE COMPLETE"
echo "  Protein   : $PROTEIN"
echo "  Completed : $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo ""
echo "Key outputs:"
ls -lh \
    "$PROCESSED" "$SOLV_IONS" \
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
echo "Logs: ${LOG_DIR}/"
ls -1 "${LOG_DIR}/"
echo "================================================================="
