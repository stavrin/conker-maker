#!/bin/sh
# Builds the Conker Maker runtime mod (.nrm). Run on Linux, macOS or in WSL:
#
#   sh runtime_mod/build.sh /path/to/CBFD-Recompiled
#
# It needs a CBFD-Recompiled checkout with N64Recomp's RecompModTool built
# (tools/N64Recomp/build/RecompModTool), clang with the MIPS target and ld.lld.
# The mod is copied in as mods/obd_core and built with the repo's own mods/build_mod.sh,
# so it always links against the syms that match that recomp build.
set -e
RECOMP=${1:?usage: build.sh /path/to/CBFD-Recompiled}
HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$RECOMP/mods/obd_core"
cp -r "$HERE/obd_core" "$RECOMP/mods/obd_core"
(cd "$RECOMP" && sh mods/build_mod.sh mods/obd_core)
mkdir -p "$HERE/build"
cp "$RECOMP/mods/obd_core/build/conker_maker_runtime.nrm" "$HERE/build/"
echo "Built $HERE/build/conker_maker_runtime.nrm: copy it into the recomp's mods folder."
