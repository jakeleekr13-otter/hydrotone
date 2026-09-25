#!/bin/zsh
# Builds the denoise bench. The binary goes to $HT_PROTO_OUT (default $TMPDIR/hydrotone-video-cleanup/denoise).
# Run it as: $HT_PROTO_OUT/bench [clip1_coral|clip2_anemone|clip3_school]  (no argument = all clips + HDR fixtures).
set -e
P=${0:A:h}; C=${P:h}
OUT=${HT_PROTO_OUT:-${TMPDIR:-/tmp}/hydrotone-video-cleanup/denoise}
mkdir -p $OUT
swiftc -O -swift-version 6 $C/TemporalDenoiser.swift $P/main.swift -o $OUT/bench
