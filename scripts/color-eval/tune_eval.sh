#!/bin/zsh
# Usage: tune_eval.sh <outName>
# Tuning scorecard: market before/after pairs + neutral ramp, UIEB best/middle/worst, real photos (no reference),
# and the 40-image UIEB dev split. Prints report.txt and writes sheets under $HT_EVAL_OUT/<outName>.
set -e
source ${0:A:h}/common.sh
O=$HT_EVAL_OUT/$1
build_eval $O
mkdir -p $O/market $O/bmw $O/dev $O/real
M=$HT_EVAL_OUT/cache/market; mkdir -p $M/raw $M/ref
cp $HT_EVAL_MARKET/raw/*.png $M/raw/ && cp $HT_EVAL_MARKET/ref/*.png $M/ref/
python3 $HERE/make_neutral_ramp.py $M/raw/n_grey.png $M/ref/n_grey.png
real_links $HT_EVAL_OUT/cache/real
cd $O
./eval $M/raw $M/ref market.csv all market > market.log 2>&1
./eval $UIEB/raw-890 $UIEB/reference-890 bmw.csv dev:0 bmw $HERE/bmw_names.txt > bmw.log 2>&1
./eval $HT_EVAL_OUT/cache/real - real.csv all real > real.log 2>&1
./eval $UIEB/raw-890 $UIEB/reference-890 uieb.csv dev:28 dev $HERE/visual_names.txt > dev.log 2>&1
python3 $HERE/summary.py uieb.csv scores.json dev > summary.md
python3 $HERE/tune_report.py $O > report.txt
cat report.txt
