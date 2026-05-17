#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Install all dependencies needed by flow-iosched scripts.
#
# Covers:
#   build-kernel.sh    — base-devel, bc, curl, git, python, elfutils
#   run-benchmarks.sh  — fio
#   plot-results.py    — python-matplotlib

set -euo pipefail

echo "Installing flow-iosched dependencies..."
sudo -v

# Base build tools (gcc, make, patch, etc.)
sudo pacman -S --noconfirm --needed base-devel bc curl git python elfutils

# Benchmark tools
sudo pacman -S --noconfirm --needed fio python-matplotlib

echo ""
echo "Done. You can now build kernels, run benchmarks, and generate charts:"
echo "  sudo ./bench-tests/build-kernel.sh 7.0.8"
echo "  sudo ./bench-tests/run-benchmarks.sh"
echo "  python3 bench-tests/plot-results.py"
