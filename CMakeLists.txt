cmake_minimum_required(VERSION 3.18)
project(mpi_bandwidth LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(MPI REQUIRED COMPONENTS C)

add_executable(mpi_bandwidth src/mpi_bandwidth.c)
target_link_libraries(mpi_bandwidth PRIVATE MPI::MPI_C)

# Options mpiexec propres à l'environnement.
# En CI (conteneur root, peu de coeurs) :
#   -DMPIEXEC_PREFLAGS="--allow-run-as-root;--oversubscribe"
set(TEST_NPROCS 4 CACHE STRING "Nombre (pair) de processus MPI pour le test")

enable_testing()

# Test nominal : nombre pair de tâches, le tableau final doit être affiché.
add_test(NAME bandwidth_np${TEST_NPROCS}
         COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} ${TEST_NPROCS}
                 ${MPIEXEC_PREFLAGS} $<TARGET_FILE:mpi_bandwidth> ${MPIEXEC_POSTFLAGS})
set_tests_properties(bandwidth_np${TEST_NPROCS} PROPERTIES
                     TIMEOUT 120
                     PASS_REGULAR_EXPRESSION "OVERALL AVERAGES")

# Test négatif : un nombre impair de tâches doit être refusé (code non nul).
add_test(NAME bandwidth_odd_np3_rejected
         COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 3
                 ${MPIEXEC_PREFLAGS} $<TARGET_FILE:mpi_bandwidth> ${MPIEXEC_POSTFLAGS})
set_tests_properties(bandwidth_odd_np3_rejected PROPERTIES
                     TIMEOUT 60
                     WILL_FAIL TRUE)
