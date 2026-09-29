#!/bin/zsh
# Focused native macOS checks of the shipping Core Image kernel and CPU mirror.
set -e
source ${0:A:h}/common.sh
O=$HT_EVAL_OUT/native-checks
build_eval $O $HERE/native_checks.swift
$O/eval
