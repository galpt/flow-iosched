#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Install benchmark dependencies for flow-iosched.
# Installs fio and python-matplotlib needed by run-benchmarks.sh and plot-results.py.

set -euo pipefail

echo "Installing benchmark dependencies..."
sudo -v
sudo pacman -S --noconfirm fio python-matplotlib
echo ""
echo "Done. You can now run benchmarks and generate charts:"
echo "  sudo ./bench-tests/run-benchmarks.sh"
echo "  python3 bench-tests/plot-results.py"
