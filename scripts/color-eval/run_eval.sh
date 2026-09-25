#!/bin/zsh
# Usage: run_eval.sh <outName> [dev:28|holdout:40|all]
# UIEB split plus the first 8 challenging-60 images. Writes summary.md, scores.json and sheets under $HT_EVAL_OUT/<outName>.
set -e
source ${0:A:h}/common.sh
O=$HT_EVAL_OUT/$1; SPLIT=${2:-dev:28}
build_eval $O
mkdir -p $O/sheet $O/challenging
$O/eval $UIEB/raw-890 $UIEB/reference-890 $O/uieb.csv $SPLIT $O/sheet $HERE/visual_names.txt > $O/uieb.log 2>&1
$O/eval $UIEB/challenging-60 - $O/challenging.csv 8 $O/challenging > $O/challenging.log 2>&1
if [[ $SPLIT == all ]]; then python3 $HERE/summary.py $O/uieb.csv $O/scores.json > $O/summary.md
else python3 $HERE/summary.py $O/uieb.csv $O/scores.json ${SPLIT%%:*} > $O/summary.md; fi
python3 $HERE/sheet.py $O/sheet $O/sheet_uieb.jpg
python3 $HERE/sheet.py $O/challenging $O/sheet_challenging.jpg
echo "run_eval done: $O"
