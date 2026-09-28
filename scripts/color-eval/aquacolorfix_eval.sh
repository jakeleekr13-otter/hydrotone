#!/bin/zsh
# Usage: aquacolorfix_eval.sh <outName> [sourcesDir]
# Development gate from docs/AquaColorFixBenchmark.md: renders the five AquaColorFix sources (O1-O5) with the
# working-tree Processing sources (or another folder), then scores the photo path (`combined`) and the video
# path (`uniform`) against the AquaColorFix outputs. Prints one line per path; the full report, CSV and the
# comparison sheet are under $HT_EVAL_OUT/<outName>/bench and bench-uniform. aqua.log holds the analysis and
# correction values of every pair (HT_EVAL_LOG).
set -e
source ${0:A:h}/common.sh
O=$HT_EVAL_OUT/$1
export HT_EVAL_SOURCES=${2:-$HT_EVAL_SOURCES}
build_eval $O
DATA=$HT_EVAL_DATA/aquacolorfix
RAW=$HT_EVAL_OUT/cache/aquacolorfix/raw; REF=$HT_EVAL_OUT/cache/aquacolorfix/ref
rm -rf $RAW $REF; mkdir -p $RAW $REF $O/sheet
for n in 1 2 3 4 5; do
    ln -s $DATA/O$n.* $RAW/p$n.jpg
    ln -s $DATA/A$n.* $REF/p$n.jpg
done
( cd $O && HT_EVAL_MAXDIM=960 HT_EVAL_LOG=1 ./eval $RAW $REF aqua.csv all sheet > aqua.log 2>&1 )
python3 $HERE/aquacolorfix_benchmark.py --hydro-files "$O/sheet/p{n}__combined.jpg" --label "$1" --output $O/bench | grep "^$1:"
python3 $HERE/aquacolorfix_benchmark.py --hydro-files "$O/sheet/p{n}__uniform.jpg" --label "$1-uniform" --output $O/bench-uniform | grep "^$1-uniform:"
