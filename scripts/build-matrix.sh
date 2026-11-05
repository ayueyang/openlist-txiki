#!/bin/sh
# 出四变体（标准/精简前端 × 自带/共用 tjs）。参数化入口，不允许手工改四遍。
#
# 用法（仓库根）：
#   OUT_DIR=artifacts/release-matrix-1010 sh scripts/apk/build-matrix.sh
# 可选：VERSION（默认 0.1.0-r40）、BASE_STAGE、WORK_ROOT、SRC_ARCHIVE、DOCKER_IMAGE
# 前置：FRONTEND 的两份 dist 已经由同目录的 fetch-frontend.sh 落盘到
#       work/frontend/{standard,lite}/dist
# 布局：脚本在 scripts/apk/（开发树）或 scripts/（发布归档/公开仓）都能跑，
#       入口按脚本自身目录定位 build-variant.py。
set -eu
: "${OUT_DIR:?必须给 OUT_DIR（交件目录）}"
VERSION=${VERSION:-0.1.0-r40}
HERE=$(dirname -- "$0")

for fe in standard lite; do
	for rt in bundled shared; do
		echo "=== FRONTEND=$fe TJS=$rt ==="
		FRONTEND=$fe TJS=$rt VERSION=$VERSION OUT_DIR=$OUT_DIR python "$HERE/build-variant.py"
	done
done
