#!/bin/zsh
# Runs the 4 measured segments and the speed tests. Build first with build.sh.
OUT=${HT_PROTO_OUT:-${TMPDIR:-/tmp}/hydrotone-video-cleanup/particles}
cd $OUT
./bench run S1_c3_snow c3 29.5 6 || echo "S1 FAILED $?"
./bench run S2_c3_school c3 10.5 8 700 500 || echo "S2 FAILED $?"
./bench run S3_c1_fish c1 0 4 760 150 || echo "S3 FAILED $?"
./bench run S4_c2_anemone c2 18 6 860 130 || echo "S4 FAILED $?"
./bench speed c3 30 || echo "SPEED FAILED $?"
./bench speed c1 0 || echo "SPEED FAILED $?"
