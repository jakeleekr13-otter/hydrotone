#!/bin/zsh
# Native macOS still-image evaluation; no simulator. Optional second argument: baseline render directory.
set -e
source ${0:A:h}/common.sh
O=$HT_EVAL_OUT/${1:?Usage: m5_eval.sh run-name [baseline-render-directory]}
build_eval $O
mkdir -p $O/raw $O/ref $O/render
ln -sfn $HT_EVAL_MARKET/raw/m5.png $O/raw/m5.png
ln -sfn $HT_EVAL_MARKET/ref/m5.png $O/ref/m5.png
HT_EVAL_PNG=1 HT_EVAL_MAXDIM=1600 HT_EVAL_LOG=1 $O/eval $O/raw $O/ref $O/m5.csv all $O/render > $O/m5.log 2>&1
report_args=($O/render)
if [[ -n ${2:-} ]]; then report_args+=(--baseline "$2"); fi
python3 $HERE/m5_report.py "${report_args[@]}" > $O/report.txt
cat $O/report.txt
