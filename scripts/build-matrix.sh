#!/bin/sh
# 出四变体（标准/精简前端 × 自带/共用 tjs）。参数化入口，不允许手工改四遍。
#
# 用法（仓库根）：
#   OUT_DIR=artifacts/release-matrix-1010 sh scripts/apk/build-matrix.sh
# 可选：VERSION（默认 0.1.0-r40）、BASE_STAGE、WORK_ROOT、SRC_ARCHIVE、DOCKER_IMAGE
# 前置：FRONTEND 的两份 dist 已经由 scripts/apk/fetch-frontend.sh 落盘到
#       work/frontend/{standard,lite}/dist
set -eu
: "${OUT_DIR:?必须给 OUT_DIR（交件目录）}"
VERSION=${VERSION:-0.1.0-r40}

for fe in standard lite; do
	for rt in bundled shared; do
		echo "=== FRONTEND=$fe TJS=$rt ==="
		FRONTEND=$fe TJS=$rt VERSION=$VERSION OUT_DIR=$OUT_DIR python scripts/apk/build-variant.py
	done
done
