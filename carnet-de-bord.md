# Carnet de bord – TP3 DevOps pour le HPC

Auteur : Amin (monôme) – M2 CHPS, CHPS0902
Dépôt : <https://github.com/Le-Amin/TP_Devops_HPC> (GitHub Actions, runners partagés)
Cluster : ROMEO (Université de Reims), runner auto-hébergé sur le nœud de connexion `romeo1`
Code : `src/mpi_bandwidth.c` (tutoriel MPI du LLNL), commit évalué tagué `seance-inversee`

Choix de départ :

| Sujet | Choix | Raison |
|---|---|---|
| Forge | GitHub + GitHub Actions | compte existant ; un `.gitlab-ci.yml` équivalent est fourni (non exécuté) |
| Code | `mpi_bandwidth.c` (LLNL) | code réel du cours 5, mesure un débit point à point |
| Cluster (mission 3) | ROMEO | crédits GCP non utilisés ; vrai centre de calcul avec Slurm, modules et Spack |
| CI → cluster | runner auto-hébergé sur `romeo1` (label `hpc-login`) | `romeo1` joint `github.com` en HTTPS sortant, pas besoin d'ouvrir de port entrant |
| Spack (mission 4) | installation partagée de ROMEO (Spack 1.0.1) | environnement dédié `~/tp3-spack` |

---

## Mission 1 – Pipeline minimal

### Ce qui a été fait

- `CMakeLists.txt` : cible `mpi_bandwidth` liée à `MPI::MPI_C`, avec deux tests CTest :
  - `bandwidth_np4` : 4 processus, réussi si la sortie contient `OVERALL AVERAGES` ;
  - `bandwidth_odd_np3_rejected` : 3 processus, **doit échouer** (`WILL_FAIL`), car le code exige un nombre pair de tâches.
- `.github/workflows/ci.yml` : job `build` puis job `test`, tous deux dans le conteneur `gcc:13-bookworm` (CMake et OpenMPI installés par `apt-get`, l'équivalent du `before_script`). `test` lance `ctest`, puis `mpirun -np 4 --allow-run-as-root --oversubscribe`.
- Passage des binaires : `actions/upload-artifact` dans `build`, `actions/download-artifact` et `needs: build` dans `test` (équivalent de `artifacts:` + `needs:`).
- Deux correctifs minimes dans le code LLNL, marqués `TP3` : `rc` était passé non initialisé à `MPI_Abort` (signalé par `gcc -Wall`, `-Wmaybe-uninitialized` ; cppcheck ne le voit pas), et `return 0` explicite.

### Preuves d'exécution

Run [40217519553](https://github.com/Le-Amin/TP_Devops_HPC/actions/runs/40217519553) : `build` ✓ (35 s), `test` ✓ (35 s).

```
1/2 Test #1: bandwidth_np4 ....................   Passed    0.43 sec
2/2 Test #2: bandwidth_odd_np3_rejected .......   Passed    0.29 sec
100% tests passed, 0 tests failed out of 2

task    0 is on c6a2e68a1447 partner=   2      <- les 4 rangs sont dans le même conteneur
***Message size:  1000000 *** best  /  avg  / worst (MB/sec)
   OVERALL AVERAGES:          13699.93 / 10512.30 / 5106.72
```

### Questions de cadrage

**Deux jobs d'un même stage échouent : le pipeline continue-t-il ?**
Non. Les jobs d'un même stage vont tous jusqu'au bout (on voit donc les deux échecs d'un coup), mais le stage suivant n'est pas lancé : ses jobs passent en *skipped*. Constaté au premier run (40217427817) : `build` a échoué, et `test`, `package` et `registry-login` ont été ignorés. C'est souhaitable : on ne teste pas un binaire qui n'existe pas, on ne publie pas un paquet non testé, et on économise des minutes de runner. L'erreur reste aussi lisible, à sa source, sans cascade d'échecs secondaires.

**mpirun dans le conteneur CI vs sur un cluster ?**
Dans le CI, tous les rangs tournent dans **un seul conteneur, sur une seule VM** (même nom d'hôte pour les 4 tâches). La communication passe par la mémoire partagée (environ 10 500 Mo/s en moyenne pour 1 Mo). On est root (d'où `--allow-run-as-root`), avec 2 à 4 cœurs (d'où `--oversubscribe`), et sans ordonnanceur. Sur ROMEO (mission 3), les 8 rangs sont répartis sur `romeo-c023` et `romeo-c040` par Slurm, et les paires communiquent **entre nœuds** à environ 600 Mo/s. Le CI vérifie que le code compile et donne un résultat correct ; il ne dit rien des performances, du réseau, du placement ni des modules du cluster. CI ≠ exécution cluster.

**Pourquoi le test échoue-t-il sans `needs:` alors que le build a réussi ?**
Sans `needs:`, rien ne dit que `test` dépend de `build` : les deux démarrent en même temps sur deux runners différents. `test` cherche alors un artifact qui n'existe pas encore (« Artifact not found »), et chaque job part d'un environnement vierge, donc le binaire n'y est pas. Expérience faite sur une branche jetable (`exp-sans-needs`, run [40221172119](https://github.com/Le-Amin/TP_Devops_HPC/actions/runs/40221172119)) : les deux jobs ont démarré ensemble, et `test` est **passé par chance**. Le pull de l'image et `apt-get` ont pris environ 57 s, si bien que `build` (42 s) avait déjà publié l'artifact quand `download-artifact` l'a demandé. C'est une condition de course, pire qu'un échec franc : le pipeline peut devenir rouge le jour où `test` va plus vite (cache d'image, miroir apt plus rapide). `needs:` rend la dépendance explicite. (En GitLab, ce sont `needs:`/`dependencies:` qui disent quels artifacts sont téléchargés ; un `needs: []` ou un `needs:` qui oublie `build` donne le même effet.)

### Erreurs rencontrées et résolution

| Erreur | Cause | Résolution |
|---|---|---|
| `update-alternatives: error: alternative path /usr/bin/gfortran doesn't exist` puis `dpkg returned an error code (1)` (run 40217427817) | L'image officielle `gcc` installe son compilateur dans `/usr/local` et détourne les binaires Debian (`dpkg-divert`). `libopenmpi-dev` tire le paquet `gfortran` (via `libcoarrays-openmpi-dev`), dont le script de post-installation échoue. | `ln -sf /usr/local/bin/gfortran /usr/bin/gfortran` avant `apt-get` (commit 7e5371d) |
| Bit exécutable perdu après `download-artifact` | Les artifacts GitHub ne conservent pas les permissions Unix | `chmod +x build/mpi_bandwidth` dans `test` (anticipé) |

### Bilan

- Ça marche : build et test sur un runner partagé, binaire transmis par artifact, test négatif (nombre impair de processus) compris.
- Ça ne marche pas : rien de bloquant ; l'installation d'OpenMPI par `apt` coûte environ 30 s à chaque job.
- Je referais : une image Docker préparée (gcc + OpenMPI + CMake) publiée une fois, pour supprimer l'`apt-get` et ce genre de piège.

---

## Mission 2 – Déclencheurs, règles et secrets

### Ce qui a été fait

| Job | Condition (GitHub Actions) | Équivalent GitLab (`.gitlab-ci.yml`) |
|---|---|---|
| `lint` (cppcheck) | `if: github.event_name == 'pull_request'` | `rules: - if: $CI_PIPELINE_SOURCE == "merge_request_event"` |
| `package` (tarball + sha256sum) | `on.push.tags: ['v*.*.*']` + `if: startsWith(github.ref, 'refs/tags/v')` | `rules: - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/` |
| `registry-login` | `environment: registry` (protégé, branche `main` uniquement), secret `REGISTRY_PASSWORD` | variable masquée + protégée |

Le secret est passé par `--password-stdin` : `echo "$REGISTRY_PASSWORD" | docker login ... --password-stdin`. Il n'apparaît jamais dans la ligne de commande (visible dans `ps`, dans l'historique ou dans une trace `set -x`).

### Preuves d'exécution

- **lint sur PR uniquement** : PR #1 (`mission2-lint`, ajout de `-Wall -Wextra`), run 40217693214 : `lint` ✓ (20 s). Sur les push vers `main`, `lint` apparaît *skipped*.
- **package sur tag** : tag `v1.0.0` → job `package` (tarball + `sha256sum -c`). _Preuve à compléter après le push du tag._
- **secret masqué**, run [40221117808](https://github.com/Le-Amin/TP_Devops_HPC/actions/runs/40221117808) :
  ```
  env:
    REGISTRY_PASSWORD: ***
  Secret affiché dans les logs : ***
  Error response from daemon: Get "https://registry.example.invalid/v2/": dial tcp: lookup registry.example.invalid ... no such host
  Échec attendu : registre fictif
  ```
- **protection** : sur la branche `exp-sans-needs` (run 40221172119) :
  ```
  Branch "exp-sans-needs" is not allowed to deploy to registry due to environment protection rules.
  ```

### Questions de cadrage

**`rules:` vs `only:/except:`**
Il faut écrire **`rules:`**. `only:/except:` n'est plus développé : la documentation GitLab le présente comme obsolète au profit de `rules:`, qui sait combiner plusieurs conditions (`if`, `changes`, `exists`), choisir `when:` (manual, delayed, never) et définir des variables par règle. On retrouve `only:/except:` dans les **anciens pipelines** et les templates historiques (et dans les diapositives et tutoriels anciens) : il faut savoir le lire pour migrer. Les deux ne peuvent pas être mélangés dans un même job.

**Variable « Protected » lancée depuis une branche non protégée ?**
Elle n'est **pas injectée** : dans le job, elle est vide. Je l'ai vérifié avec l'équivalent GitHub (secret d'un Environment limité à `main`) : depuis `exp-sans-needs`, le job est même refusé avant de démarrer. Le risque couvert : n'importe quel développeur (ou une contribution externe) peut créer une branche et y modifier le YAML pour faire `echo $SECRET | curl attaquant`. En réservant le secret aux branches et tags protégés, où seuls les mainteneurs poussent et où les fusions sont relues, on empêche cette exfiltration.

**Pourquoi jamais de secret dans le YAML, même « temporairement » ?**
Git n'oublie rien : le secret reste dans l'historique, dans tous les clones et forks, et dans les caches de la forge, même après un commit qui le retire. Il faut alors le révoquer et le changer. Le YAML est lisible par tout lecteur du dépôt (le mien est public) ; des robots scannent GitHub en continu à la recherche de clés. Et un secret écrit en clair n'est pas masqué dans les logs. Le mécanisme des variables CI apporte au contraire le masquage, la protection par branche et la rotation sans commit.

### Erreurs rencontrées et résolution

- `registry-login` rouge tant que l'Environment `registry` et son secret n'existaient pas (`::error::secret REGISTRY_PASSWORD absent`) : comportement voulu (on échoue plutôt que de continuer sans secret). Résolu en créant l'Environment.
- Tags non poussables depuis le conteneur de travail (HTTP 403 du proxy) : tags poussés depuis le poste local.
- La PR #1 a été fermée automatiquement par GitHub quand l'historique a été réécrit (réattribution des commits au compte Le-Amin) : la branche n'avait plus d'ancêtre commun avec `main`. Ce n'est pas bloquant, le run lint était déjà acquis.

### Bilan

- Ça marche : lint seulement sur PR, package seulement sur tag `vX.Y.Z`, secret masqué et réservé à `main`.
- Ça ne marche pas : `docker login` échoue (registre fictif, attendu).
- Je referais : configurer l'Environment protégé avant le premier push, pour ne pas avoir de pipeline rouge « normal ».

---

## Mission 3 – Du CI vers Slurm (ROMEO)

### Ce qui a été fait

- **Runner** GitHub 2.338.1 installé dans `~/actions-runner` sur `romeo1` (sur GPFS, donc visible des nœuds de calcul), nom `romeo1-ambraham`, labels `self-hosted, Linux, X64, hpc-login`, lancé dans une session `tmux` (`gh-runner`), sans sudo. Le jeton d'enregistrement (valable 1 h, à usage unique) n'est écrit nulle part dans le dépôt.
- **`slurm/job_ci.sh`**, adapté à ROMEO après `sinfo` et `sbatch --test-only` :
  - `--account=r250127` : sans lui, « Account is missing: use option --account=<your_account> » ;
  - `--partition=instant` (pas de partition `debug` ; `instant` est la partition par défaut, limitée à 1 h) ;
  - `--constraint=x64cpu` : les partitions mélangent des nœuds x86 (`romeo-c…`) et ARM+GPU (`romeo-a…`), et le binaire est compilé en x86 sur `romeo1` ;
  - 2 nœuds × 4 tâches, `--mem-per-cpu=500M` (la mémoire est obligatoire), `--time=00:05:00` ;
  - environnement : `source /etc/profile; romeo_load_x64cpu_env; module load openmpi/gnu/4.1.7`. Sur ROMEO, `romeo_load_x64cpu_env` est une fonction shell qui source le `setup-env.sh` de Spack x86, puis on charge le module OpenMPI ;
  - `mpirun` sans `-np` (OpenMPI lit l'allocation Slurm), puis `SUCCESS` ou `FAILURE (code n)`.
- **`.github/workflows/slurm.yml`**, déclenché par `workflow_dispatch` (choix `polling` ou `wait`) et par un **nightly** `cron: '0 2 * * *'` :
  - compilation avec `mpicc` sur `romeo1` ;
  - `JOBID=$(sbatch --parsable ...)` ;
  - `slurm/wait_job.sh` : polling de `sacct` toutes les 15 s, affichage de la raison et du début estimé quand le job est `PENDING`, puis vérification d'`ExitCode = 0:0` **et** de la présence de `SUCCESS` dans le log ;
  - `timeout-minutes: 30` (équivalent de `timeout:`) ;
  - `scancel` si le pipeline est annulé ou expire (`if: cancelled()`) ;
  - logs Slurm conservés en artifact avec `if: always()` (équivalent de `artifacts: when: always`) ;
  - `concurrency: slurm-romeo` : un seul pipeline Slurm à la fois.
- Côté GitLab (`.gitlab-ci.yml`, job `slurm`) : `tags: [hpc-login]`, `timeout: 30m`, `retry: max: 1, when: runner_system_failure`, `artifacts: when: always`.

### Preuves d'exécution

Run polling [40220107921](https://github.com/Le-Amin/TP_Devops_HPC/actions/runs/40220107921) ✓ (26 s) :

```
Job Slurm soumis : 784202
Job 784202 terminé
JobID             State ExitCode    Elapsed        NodeList
784202        COMPLETED      0:0   00:00:06 romeo-c[023,04+
== Job 784202 : 8 tâches sur 2 noeuds (romeo-c[023,040])
Currently Loaded Modulefiles:
 1) openmpi/gnu/4.1.7
task    0 is on romeo-c023 partner=   4
...
task    4 is on romeo-c040 partner=   0
***Message size:  1000000 *** best  /  avg  / worst (MB/sec)
   OVERALL AVERAGES:          886.39 / 600.45 / 487.68
SUCCESS
```

Run `sbatch --wait` [40220198853](https://github.com/Le-Amin/TP_Devops_HPC/actions/runs/40220198853) ✓ (20 s).

Observation : environ 600 Mo/s entre nœuds, c'est bas pour un cluster de ce niveau. Le `spack.lock` de la mission 4 montre que l'OpenMPI 4.1.7 gcc du site est construit avec `fabrics:=none` (pas d'UCX). Le module `openmpi/gnu/4.1.7` utilisé ici est probablement ce même build, et les messages passeraient alors par TCP plutôt que par le réseau rapide. C'est une piste à vérifier (`ompi_info | grep btl`) avant toute mesure de performance sérieuse.

### Polling vs `sbatch --wait`

- `sbatch --wait` : 3 lignes, le code retour du job remonte tout seul ; idéal pour un job court, sur une file peu chargée, quand on veut juste « vert ou rouge ».
- Polling (`--parsable` + `sacct`) : plus de code, mais l'attente devient observable (état et raison du `PENDING` dans le log CI), on peut récupérer `ExitCode`, `Elapsed` et `NodeList`, et faire un `scancel` propre en cas d'annulation ; à choisir pour les nightly et les files chargées.
- Dans les deux cas, le runner reste occupé pendant toute l'attente ; avec `--wait`, une coupure SSH ou du runner perd le suivi, alors qu'avec le polling on garde le `JOBID`.

### Questions de cadrage

**Pourquoi un `timeout:` CI alors que Slurm a déjà un wall-time ?**
Le wall-time Slurm ne compte qu'à partir du **démarrage** du job. Le temps passé en `PENDING` (file saturée, maintenance, réservation) n'est pas borné, pas plus qu'un `sacct` qui ne répond plus, un runner bloqué ou une compilation qui boucle avant `sbatch`. Sans `timeout:`, le job CI peut monopoliser le runner (le seul qui joint le cluster) pendant des heures et bloquer tous les pipelines suivants (et `concurrency:` les met en file). Le timeout CI borne **tout le cycle** côté CI, et `scancel` sur annulation évite de laisser un job orphelin dans la file.

**Job `PENDING` 20 minutes : que se passe-t-il côté GitLab, et comment le rendre observable ?**
Côté forge, le job CI est simplement « running » : il consomme son `timeout:` et occupe le runner, sans rien dire de plus si on fait `sbatch --wait`. Pour le rendre observable, `wait_job.sh` affiche à chaque tour l'état, la **raison** et le **début estimé** :
`HH:MM:SS PENDING - <raison>, début estimé <date>` (via `squeue -o '%r, %S'` : `Priority`, `Resources`, `QOSMaxJobsPerUserLimit`…). Je n'ai pas eu de vrai `PENDING` pendant la séance (job démarré immédiatement) ; `sbatch --test-only` annonçait pourtant un démarrage estimé une heure plus tard, ce qui montre que l'estimation de Slurm est indicative. On peut aussi publier le `JOBID` en sortie de step pour un `scontrol show job` manuel. Avec un timeout de 30 min, un `PENDING` de 20 min passe encore, mais le pipeline est clairement marqué comme en attente d'infrastructure, pas de code.

**Le nightly échoue à 2 h : trois questions avant de relancer.**
1. **À quelle étape** a-t-il échoué : compilation et `sbatch` (côté runner) ou exécution (`ExitCode` non nul, pas de `SUCCESS`) ? Les logs sont conservés grâce à `if: always()`.
2. **Qu'est-ce qui a changé** depuis le dernier nightly vert : commits du jour, module ou Spack du site mis à jour, maintenance annoncée de ROMEO ?
3. **Est-ce reproductible** : le même commit échoue-t-il aussi en `workflow_dispatch` ? L'état Slurm est-il `FAILED` (code), ou bien `NODE_FAIL`, `TIMEOUT`, `CANCELLED`, `PREEMPTED` (infrastructure) ? Le runner était-il en ligne ?

*Échec de code* : déterministe, le job tourne mais `ExitCode` ≠ 0 ou le test est faux ; on corrige le code, relancer ne sert à rien.
*Échec d'infrastructure* : nœud tombé, quota, file, runner hors ligne, GPFS lent ; le code n'y est pour rien et une relance (après vérification) est légitime. C'est exactement le cas que vise `retry: when: runner_system_failure` en GitLab : relancer automatiquement **seulement** quand c'est le runner qui a lâché, jamais sur un échec de script. GitHub Actions n'a pas d'équivalent natif : on relance à la main (*Re-run failed jobs*) après diagnostic.

### Erreurs rencontrées et résolution

| Erreur | Résolution |
|---|---|
| `sbatch: error: ... Account is missing` (test `--test-only`) | `#SBATCH --account=r250127` (commit 6cfce81) |
| Pas de partition `debug` | `instant` (défaut, 1 h max), vérifié par `sinfo -s` |
| Nœuds hétérogènes x86 / ARM | `--constraint=x64cpu` |
| Pas de CMake ni de `mpicc` dans le PATH par défaut | `romeo_load_x64cpu_env` + `module load openmpi/gnu/4.1.7` ; compilation directe avec `mpicc` |

### Bilan

- Ça marche : runner sur `romeo1`, soumission, polling, vérification et logs ; variantes polling et `--wait` vertes, job sur 2 nœuds réels.
- Ça ne marche pas : le runner ne redémarre pas seul (tmux, pas de service systemd). Le dépôt est public, alors qu'un runner auto-hébergé attaché à un dépôt public est un risque (une PR d'un fork pourrait exécuter du code sur ROMEO sous mon compte). Il faut passer le dépôt en privé ou arrêter le runner après la séance.
- Je referais : runner attaché à un dépôt privé, et workflow compilant via l'environnement Spack de la mission 4 plutôt que via le module.

---

## Mission 4 – Spack : l'environnement comme code

### Ce qui a été fait

```bash
source /etc/profile; romeo_load_x64cpu_env      # Spack 1.0.1 partagé de ROMEO
mkdir -p ~/tp3-spack && cd ~/tp3-spack && spack env create -d .
spack -e . compiler find                         # ajoute gcc@11.5.0 (/usr), on ne compile pas gcc
spack -e . add "openmpi@4.1.7/kfjcqqr" cmake
spack -e . install                               # 46 [^] déjà installés en amont, 0 à construire
```

Fichiers versionnés : `spack/spack.yaml`, `spack/spack.lock`, et `spack/concretize.log` (sortie de `spack spec -I -l`).

### spack.yaml vs spack.lock

- **`spack.yaml` = les intentions** (518 octets) : la liste des specs abstraites (`cmake`, `openmpi@4.1.7/kfjcqqr`), `concretizer: unify: true`, `view: true`, et le compilateur externe déclaré (`gcc@11.5.0`, prefix `/usr`, c/c++/fortran).
- **`spack.lock` = le résultat de la concrétisation** (77 Ko, `lockfile-version: 6`) : les `roots`, chacune avec son **hash** exact, et les **51 specs concrètes** du graphe complet. Pour chacune : version exacte, compilateur, **tous les variants** résolus, architecture (`linux-rhel9-zen4`) et dépendances par hash. Extrait :

```
"roots": [
  {"hash": "kfjcqqrv32tybweu6x6vkloxowsdpxad", "spec": "openmpi@4.1.7/kfjcqqr"},
  {"hash": "56vu72qwyutk7em2iklj7mqul6bx5rgv", "spec": "cmake"}
]
openmpi@4.1.7 +atomics~cuda~cxx~java+legacylaunchers+romio+rsh~static+vt+wrapper-rpath
              fabrics:=none schedulers:=slurm arch=linux-rhel9-zen4
cmake@3.31.8 ~doc+ncurses+ownlibs~qtgui build_type=Release %c,cxx=aocc@4.2.0
```

### Questions de cadrage

**Syntaxe `package@version%compiler+variant~variant`, et spec hdf5 demandée.**
`@` fixe la version (ou un intervalle `@1.14:`), `%` le compilateur (ou une dépendance de compilation en Spack 1.0), `+` active un variant booléen, `~` le désactive, `nom=valeur` fixe un variant à valeurs, `^` contraint une dépendance, `/hash` désigne une installation précise.
hdf5 avec GCC, MPI et Fortran activés, C++ désactivé :

```
hdf5@1.14.5 %gcc@11.5.0 +mpi +fortran ~cxx ^openmpi@4.1.7
```

(La version minimale demandée par le sujet serait `hdf5%gcc+mpi+fortran~cxx` ; les versions précises rendent la spec reproductible.)

**Pourquoi `spack.lock` suffit à reproduire l'environnement, et pas `spack.yaml` seul ?**
`spack.yaml` ne contient que des contraintes partielles : `cmake` signifie « une version de cmake ». Le résultat de la concrétisation dépend de la version de Spack et de ses recettes, des `packages.yaml` du site, des compilateurs et paquets déjà installés (réutilisation) et de l'architecture. Je l'ai vécu : sans contrainte, Spack a choisi le build **AOCC** d'OpenMPI au lieu du build gcc. Sur une autre machine, ou avec un Spack plus récent, `spack.yaml` peut donc donner autre chose. `spack.lock` fige **tout le graphe concret** (versions, variants, compilateurs, hash de chaque nœud) : `spack env create monenv spack.lock` puis `spack install` reconstruit exactement les mêmes specs, ou échoue explicitement si c'est impossible, au lieu de dériver en silence.

**Intérêt du buildcache pour un pipeline qui installe l'environnement à chaque fois ?**
Compiler OpenMPI et ses dépendances prend des dizaines de minutes à chaque exécution, et un compilateur des heures. Un buildcache (binaires signés indexés par hash, sur un miroir OCI ou S3) permet à `spack install` de **télécharger** les paquets dont le hash correspond, au lieu de les recompiler. Le pipeline passe de dizaines de minutes à quelques minutes, consomme moins de ressources et devient plus fiable (moins d'étapes qui peuvent casser). Le hash du `spack.lock` garantit que le binaire récupéré est bien celui attendu. Sur ROMEO, l'installation partagée joue ce rôle : 46 paquets marqués `[^]` (réutilisés depuis l'amont), **0 à construire**.

### Erreurs rencontrées et résolution

| Erreur | Cause | Résolution |
|---|---|---|
| `spack add "openmpi %gcc"` → spec insatisfiable | Le `packages.yaml` du site déclare `openmpi: buildable: false`, et les OpenMPI installés en amont n'ont pas de compilateur dans leur spec, donc `%gcc` ne correspond à rien | Épingler le build gcc par son hash : `openmpi@4.1.7/kfjcqqr` |
| `openmpi@4.1.7` seul → Spack choisit le build AOCC (`mpicc` = AMD clang) | Plusieurs builds disponibles, la préférence du site l'emporte | idem, épinglage par hash |
| `spack concretize -f` → erreur interne (« set() does not equal {'-O2'} ») | Bug de Spack 1.0.1 avec un hash épinglé portant des `cflags` | `spack install` concrétise correctement ; `spack concretize` répond ensuite « No new specs » |

### Bilan

- Ça marche : environnement dédié concrétisé, `spack.yaml` et `spack.lock` versionnés, vue `~/tp3-spack/.spack-env/view` avec `mpicc` et `cmake`, rien à recompiler.
- Ça ne marche pas : la spec dépend de l'installation partagée de ROMEO (hash du site), donc le lock n'est pas portable tel quel ailleurs ; CMake a été construit avec AOCC (ce n'est pas gênant, il ne fait que piloter la compilation).
- Je referais : utiliser l'environnement Spack directement dans `slurm.yml` (`spack env activate spack/`), et ajouter un buildcache pour un pipeline hors ROMEO.

---

## Auto-diagnostic

**Acquis**
- Écrire un pipeline à étapes dépendantes (`needs:`), avec artifacts, conditions par événement (PR, tag), secrets protégés.
- Faire la différence entre valider un code en CI et l'exécuter sur un cluster ; savoir faire franchir cette frontière au pipeline (runner sur le nœud de connexion, `sbatch --parsable`, polling, timeout, logs conservés).
- Lire une spec Spack et comprendre ce que fige un lockfile.
- Diagnostiquer à partir des logs plutôt que relancer : l'erreur gfortran et la condition de course sans `needs:` ont été comprises, pas contournées au hasard.

**Points à retravailler**
- Sécurité des runners auto-hébergés (isolation, dépôt privé, exécution sous service plutôt que dans tmux).
- Spack sur une installation partagée : préférences du site, externes, buildcache.
- Mesure de performance MPI sur ROMEO : vérifier le transport réellement utilisé (UCX/InfiniBand vs TCP).

**Usage dans mes activités CHPS**
Dans un projet d'imagerie médicale (par exemple un pipeline de reconstruction ou de segmentation sur GPU) :
- un **CI** sur chaque PR qui compile et passe des tests unitaires sur de petites images synthétiques (jamais de données patients sur un runner public, et les identifiants d'accès aux données en secrets protégés) ;
- un **nightly Slurm** sur ROMEO (nœuds `armgpu` H100) qui rejoue la reconstruction sur un jeu de référence, compare le résultat à une image de référence (PSNR/SSIM avec une tolérance) et suit le temps d'exécution, pour détecter les régressions de qualité et de performance ;
- un **environnement Spack versionné** (`spack.lock`) pour que les résultats publiés soient reproductibles par un autre membre de l'équipe ou dans un an.
