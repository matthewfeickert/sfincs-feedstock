#!/usr/bin/env bash
set -euox pipefail

cd fortran/version3

# HDF5 2.0 renamed the Fortran high-level library from libhdf5hl_fortran
# (no underscore) to libhdf5_hl_fortran (with underscore), matching the C
# HL library name (cf. https://github.com/HDFGroup/hdf5/pull/4811).
# As conda-forge currently builds against both HDF5 1.14.x and 2.x, and the
# underscored dev symlink is not consistently shipped across platforms for 1.14.x
# (present on linux-64, absent on osx-arm64), detect which name is available at
# build time.
# Once the conda-forge global pinning uses HDF5 v2.0+ this can be simplified.
if [[ -f "${PREFIX}/lib/libhdf5_hl_fortran${SHLIB_EXT}" ]]; then
    # HDF5 v2.0+
    HDF5_HL_FORTRAN_LIB="-lhdf5_hl_fortran"
else
    HDF5_HL_FORTRAN_LIB="-lhdf5hl_fortran"
fi

# Create a conda-forge-specific system makefile.
# SFINCS requires a system makefile selected via the SFINCS_SYSTEM env var.
# This makefile sources PETSc's configuration (which sets FC, FLINKER, PETSC_LIB)
# and adds the flags needed to find HDF5 and NetCDF in the conda-forge prefix.
cat > makefiles/makefile.conda_forge << MAKEFILE
# -*- mode: makefile -*-
# System makefile for conda-forge build environment

# PETSc configuration (sets FC, FLINKER, PETSC_LIB).
# FLINKER is intentionally not overridden here: PETSc was built with
# FC=mpifort, so its FLINKER is already the MPI Fortran wrapper (which
# internally delegates to the conda-forge \$FC compiler).
include \${PETSC_DIR}/lib/petsc/conf/variables
include \${PETSC_DIR}/lib/petsc/conf/rules

LIBSTELL_DIR = mini_libstell
LIBSTELL_FOR_SFINCS = mini_libstell/mini_libstell.a

# -fPIC: required for shared library creation
# -DMPI_Comm=integer: PETSc < 3.19 defined this macro in its Fortran
#   includes (petscsys.h). PETSc >= 3.19 removed it and instead exposes
#   MPI_Comm as a derived type via 'use mpi_f08' through its Fortran
#   modules. The sfincs source code still relies on the old convention
#   (e.g. 'MPI_Comm :: MPIComm' which expands to 'integer :: MPIComm'),
#   so we restore it here.
EXTRA_COMPILE_FLAGS = -fPIC -DMPI_Comm=integer \
  -I\${PETSC_DIR}/include -ffree-line-length-none -fallow-argument-mismatch

EXTRA_LINK_FLAGS = -L\${PREFIX}/lib \
  -lnetcdff -lnetcdf -lhdf5_fortran -lhdf5 -lhdf5_hl ${HDF5_HL_FORTRAN_LIB}

SFINCS_IS_A_BATCH_SYSTEM_USED = no
SFINCS_COMMAND_TO_SUBMIT_JOB =
MAKEFILE

# Environment variables required by the SFINCS build system
export SFINCS_SYSTEM=conda_forge
export PETSC_DIR="${PREFIX}"
export PETSC_ARCH=""

make --jobs="${CPU_COUNT}"

# Build a shared library from the object files.
# The upstream makefile only produces a static libsfincs.a; we create a
# shared library from the same objects plus the bundled mini_libstell objects.
PETSC_LINK_FLAGS=$(pkg-config --libs petsc 2>/dev/null || echo "-lpetsc")
# 'ar t' on macOS includes the symbol table entry '__.SYMDEF SORTED' which
# the linker would try (and fail) to open as a file. Filter to .o files only.
mpifort -shared -o libsfincs${SHLIB_EXT} \
    $(ar t libsfincs.a | grep '\.o$') mini_libstell/*.o \
    -L"${PREFIX}/lib" \
    -lnetcdff -lnetcdf -lhdf5_fortran -lhdf5 -lhdf5_hl ${HDF5_HL_FORTRAN_LIB} \
    -llapack -lblas \
    ${PETSC_LINK_FLAGS}

# Install (no make install target exists upstream)
install -d "${PREFIX}/bin"
install -m 755 sfincs "${PREFIX}/bin/"

install -d "${PREFIX}/lib"
install -m 644 libsfincs${SHLIB_EXT} "${PREFIX}/lib/"

# Create job.conda_forge files so that 'make test' can discover examples.
# The test runner (runExamples.py) looks for job.<SFINCS_SYSTEM> in each
# example directory. Copy and use the existing job.CI files.
for dir in examples/*/; do
    if [ -f "${dir}/job.CI" ]; then
        cp "${dir}/job.CI" "${dir}/job.conda_forge"
    fi
done

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
    make test --jobs="${CPU_COUNT}"
fi
