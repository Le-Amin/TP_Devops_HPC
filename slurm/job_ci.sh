#!/bin/bash
# job_ci.sh - job Slurm soumis par le pipeline CI (mission 3), cluster ROMEO.
#
# Usage : sbatch slurm/job_ci.sh [chemin/vers/mpi_bandwidth]
#
# Adaptations à ROMEO par rapport à l'énoncé (à confirmer avec sinfo) :
#  - pas de partition "debug" : on utilise la partition courte "instant" ;
#  - les partitions mélangent noeuds x86 et ARM : la contrainte x64cpu garantit
#    que le binaire x86 compilé sur romeo1 s'exécute ;
#  - l'environnement x86 s'active avec romeo_load_x64cpu_env avant module load.
#
#SBATCH --job-name=ci-mpi-bw
#SBATCH --partition=instant
#SBATCH --constraint=x64cpu
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --ntasks-per-node=4
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500M
#SBATCH --time=00:05:00
#SBATCH --output=slurm-%j.out

set -euo pipefail

BIN=${1:-build/mpi_bandwidth}

echo "== Job ${SLURM_JOB_ID} : ${SLURM_NTASKS} tâches sur ${SLURM_JOB_NUM_NODES} noeuds (${SLURM_JOB_NODELIST})"

set +u   # les scripts de profil ne supportent pas set -u
source /etc/profile
romeo_load_x64cpu_env
module load openmpi/gnu/4.1.7
set -u
module list 2>&1

# OpenMPI lit l'allocation Slurm : ni -np ni hostfile.
if mpirun "$BIN"; then
    echo "SUCCESS"
else
    rc=$?
    echo "FAILURE (code $rc)"
    exit "$rc"
fi
