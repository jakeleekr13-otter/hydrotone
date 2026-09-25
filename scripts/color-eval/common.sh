# Shared setup for the colour evaluation scripts (zsh). Source it; do not run it.
# HT_EVAL_DATA     data root (UIEB, market pairs, real photos). Default: the git-ignored fixtures folder.
# HT_EVAL_SOURCES  folder with FilterEngine, RestorationPlan, RestorationEngine, WaterModelEstimator, DepthEstimator.
# HT_EVAL_MARKET   market pairs (raw/, ref/). Default: scripts/color-eval/private/market (git-ignored).
# HT_EVAL_OUT      cache and results root. Default: $TMPDIR/hydrotone-color-eval. Never inside the repo.
HERE=${0:A:h}
REPO=${HERE:h:h}
HT_EVAL_DATA=${HT_EVAL_DATA:-$REPO/HydroToneTests/Fixtures/developersfile}
HT_EVAL_SOURCES=${HT_EVAL_SOURCES:-$REPO/HydroTone/Processing}
HT_EVAL_OUT=${HT_EVAL_OUT:-${TMPDIR:-/tmp}/hydrotone-color-eval}
# Market before/after pairs are private web images. Keep them OUTSIDE HydroToneTests/: that folder is a
# synchronized Xcode group, and same-named files in raw/ and ref/ break build-for-testing.
HT_EVAL_MARKET=${HT_EVAL_MARKET:-$HERE/private/market}
UIEB=$HT_EVAL_DATA/samples/photo
MODEL=$HT_EVAL_OUT/cache/DepthAnythingV2SmallF16P6.mlmodelc
export HT_EVAL_DATA

# build_eval <outDir>: compile the harness against HT_EVAL_SOURCES and link the depth model next to it.
build_eval() {
    local out=${1:A}
    mkdir -p $out $HT_EVAL_OUT/cache
    if [[ ! -d $MODEL ]]; then
        xcrun coremlcompiler compile $REPO/HydroTone/Resources/Models/DepthAnythingV2SmallF16P6.mlpackage $HT_EVAL_OUT/cache > $HT_EVAL_OUT/cache/model.log 2>&1 || { echo "model compile failed"; return 1; }
    fi
    local src=${HT_EVAL_SOURCES:A}
    swiftc -O -swift-version 6 -o $out/eval $HERE/main.swift $src/FilterEngine.swift $src/RestorationPlan.swift \
        $src/RestorationEngine.swift $src/WaterModelEstimator.swift $src/DepthEstimator.swift $HERE/PlanUniform.swift \
        > $out/build.log 2>&1 || { echo "harness build failed, see $out/build.log"; return 1; }
    ln -sfn $MODEL $out/DepthAnythingV2SmallF16P6.mlmodelc
}

# real_links <dir>: symlinks rNN.jpg -> the photos listed in real_set.txt, so ids stay stable.
real_links() {
    local dir=$1
    rm -rf $dir && mkdir -p $dir
    local id rel
    while read -r id rel; do
        [[ -z $id ]] && continue
        [[ -f $HT_EVAL_DATA/$rel ]] || { echo "missing real photo: $HT_EVAL_DATA/$rel"; return 1; }
        ln -s "$HT_EVAL_DATA/$rel" "$dir/${id}.jpg"
    done < $HERE/real_set.txt
}
