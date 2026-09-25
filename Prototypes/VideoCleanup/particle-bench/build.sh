#!/bin/zsh
# Builds the particle bench. The binary goes to $HT_PROTO_OUT (default $TMPDIR/hydrotone-video-cleanup/particles).
set -e
P=${0:A:h}; C=${P:h}
OUT=${HT_PROTO_OUT:-${TMPDIR:-/tmp}/hydrotone-video-cleanup/particles}
mkdir -p $OUT
swiftc -O -swift-version 6 $C/TemporalDenoiser.swift $C/ParticleFilter.swift $P/ParticleFilterV1.swift $P/common.swift $P/metric.swift $P/scan.swift $P/[a-z]*_run.swift(N) $P/main.swift -o $OUT/bench
