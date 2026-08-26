#!/bin/csh -f

# ============================================================
# make_sky130_f.csh
#
# Generate an Xcelium .f file for SKY130 FD SC HD
#
# Usage:
#
#   make_sky130_f.csh <library_root> [output.f]
#
# Example:
#
#   make_sky130_f.csh \
#     /process/hosted/skywater/sky130_opensource/sky130-pdk-libs-sky130_fd_sc_hd \
#     sky130_fd_sc_hd.f
# ============================================================

if ( $#argv < 1 ) then
    echo "Usage: $0 <sky130_library_root> [output.f]"
    exit 1
endif

set LIBROOT = "$1"

if ( $#argv >= 2 ) then
    set OUTFILE = "$2"
else
    set OUTFILE = "sky130_fd_sc_hd.f"
endif

set CELLS  = "$LIBROOT/cells"
set MODELS = "$LIBROOT/models"

# ------------------------------------------------------------
# Check library
# ------------------------------------------------------------

if ( ! -d "$LIBROOT" ) then
    echo "ERROR: Library does not exist:"
    echo "  $LIBROOT"
    exit 1
endif

if ( ! -d "$CELLS" ) then
    echo "ERROR: Cannot find:"
    echo "  $CELLS"
    exit 1
endif

# ------------------------------------------------------------
# Temporary files
# ------------------------------------------------------------

set TMPDIR = "/tmp/sky130_f_$$"

mkdir -p "$TMPDIR"

if ( $status != 0 ) then
    echo "ERROR: Cannot create temporary directory"
    exit 1
endif

# ------------------------------------------------------------
# Find include directories
# ------------------------------------------------------------

find "$CELLS" -type d | sort > "$TMPDIR/cell_dirs"

if ( -d "$MODELS" ) then
    find "$MODELS" -type d | sort > "$TMPDIR/model_dirs"
else
    touch "$TMPDIR/model_dirs"
endif

# ------------------------------------------------------------
# Find wrapper source files
# ------------------------------------------------------------

find "$CELLS" -type f -name 'sky130_fd_sc_hd__*.v' | \
    grep -v '\.functional\.v$' | \
    grep -v '\.behavioral\.v$' | \
    grep -v '\.blackbox\.v$' | \
    grep -v '\.symbol\.v$' | \
    grep -v '\.specify\.v$' | \
    grep -v '\.tb\.v$' | \
    grep -v '\.functional\.pp\.v$' | \
    grep -v '\.behavioral\.pp\.v$' | \
    grep -v '\.pp\.blackbox\.v$' | \
    grep -v '\.pp\.symbol\.v$' | \
    sort > "$TMPDIR/sources"

# ------------------------------------------------------------
# Generate output
# ------------------------------------------------------------

echo "# ============================================================" > "$OUTFILE"
echo "# SKY130 FD SC HD Xcelium library" >> "$OUTFILE"
echo "# ============================================================" >> "$OUTFILE"
echo "#" >> "$OUTFILE"
echo "# Generated: `date`" >> "$OUTFILE"
echo "# Library:  $LIBROOT" >> "$OUTFILE"
echo "#" >> "$OUTFILE"
echo "# ============================================================" >> "$OUTFILE"
echo "" >> "$OUTFILE"

echo "# ------------------------------------------------------------" >> "$OUTFILE"
echo "# Cell include directories" >> "$OUTFILE"
echo "# ------------------------------------------------------------" >> "$OUTFILE"

foreach DIR (`cat "$TMPDIR/cell_dirs"`)
    echo "-incdir $DIR" >> "$OUTFILE"
end

echo "" >> "$OUTFILE"
echo "# ------------------------------------------------------------" >> "$OUTFILE"
echo "# Model include directories" >> "$OUTFILE"
echo "# ------------------------------------------------------------" >> "$OUTFILE"

foreach DIR (`cat "$TMPDIR/model_dirs"`)
    echo "-incdir $DIR" >> "$OUTFILE"
end

echo "" >> "$OUTFILE"
echo "# ------------------------------------------------------------" >> "$OUTFILE"
echo "# SKY130 cell wrapper source files" >> "$OUTFILE"
echo "# ------------------------------------------------------------" >> "$OUTFILE"

cat "$TMPDIR/sources" >> "$OUTFILE"

echo "" >> "$OUTFILE"
echo "# Allow .v library lookup" >> "$OUTFILE"
echo "+libext+.v" >> "$OUTFILE"

# ------------------------------------------------------------
# Clean up
# ------------------------------------------------------------

rm -rf "$TMPDIR"

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

set NINC = `grep -c '^-incdir ' "$OUTFILE"`
set NSRC = `grep -c '^/' "$OUTFILE"`

echo ""
echo "============================================================"
echo "SKY130 Xcelium library file generated"
echo "============================================================"
echo ""
echo "Output file:"
echo "  $OUTFILE"
echo ""
echo "Include directories:"
echo "  $NINC"
echo ""
echo "Cell source files:"
echo "  $NSRC"
echo ""
echo "Use it with:"
echo ""
echo "  xrun -f $OUTFILE my_design.v my_testbench.sv"
echo ""

