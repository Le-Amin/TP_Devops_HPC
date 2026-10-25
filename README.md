# TP3 – DevOps pour le HPC

Code de référence : `src/mpi_bandwidth.c` (tutoriel MPI du LLNL, Blaise Barney),
avec deux correctifs minimes signalés en commentaire `TP3`.

| Élément | Fichier |
|---|---|
| Build + tests CTest | `CMakeLists.txt` |
| Pipeline CI (missions 1-2) | `.github/workflows/ci.yml` (équivalent GitLab : `.gitlab-ci.yml`) |
| CI vers Slurm (mission 3) | `.github/workflows/slurm.yml`, `slurm/job_ci.sh`, `slurm/wait_job.sh` |
| Environnement Spack (mission 4) | `spack/spack.yaml`, `spack/spack.lock` |
| Carnet de bord | `carnet-de-bord.md` |

Build local :

```bash
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
```
