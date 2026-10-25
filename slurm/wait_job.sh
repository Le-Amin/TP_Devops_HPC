#!/bin/bash
# wait_job.sh JOBID - attend la fin d'un job Slurm par polling de sacct,
# rend l'attente observable (raison du PENDING) puis vérifie le résultat.
set -uo pipefail
JOBID=$1
POLL=${POLL:-15}

while true; do
    STATE=$(sacct -j "$JOBID" -X -n -P -o State | head -n1 | cut -d' ' -f1)
    case "$STATE" in
        COMPLETED)
            echo "Job $JOBID terminé"; break ;;
        PENDING)
            echo "$(date +%T) PENDING - $(squeue -j "$JOBID" -h -o '%r, début estimé %S')" ;;
        ""|CONFIGURING|RUNNING|COMPLETING)
            echo "$(date +%T) ${STATE:-inconnu (sacct pas encore à jour)}" ;;
        *)
            echo "::error::Job $JOBID terminé en état $STATE"
            sacct -j "$JOBID" -o JobID,State,ExitCode,Elapsed,NodeList
            cat "slurm-${JOBID}.out" 2>/dev/null
            exit 1 ;;
    esac
    sleep "$POLL"
done

sacct -j "$JOBID" -o JobID,State,ExitCode,Elapsed,NodeList
cat "slurm-${JOBID}.out"
EXIT=$(sacct -j "$JOBID" -X -n -P -o ExitCode)
[ "$EXIT" = "0:0" ] && grep -q '^SUCCESS' "slurm-${JOBID}.out"
