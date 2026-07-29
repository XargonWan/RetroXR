#!/usr/bin/env bash
# Build the Linux targets from WSL. Run as: wsl -d Ubuntu -- bash /mnt/c/.../build_linux.sh
# WSL inherits the Windows environment here, so HOME and PATH both have to be
# reset explicitly -- the inherited PATH contains spaces and breaks a bare export.
set -u
export HOME=/home/user
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cd /mnt/c/Users/user/SK.Libretro.Godot || exit 1
echo "== scons: $(command -v scons)"
echo "== g++:   $(g++ --version | head -1)"
for t in template_debug template_release; do
  echo "===== linux $t ====="
  scons platform=linux arch=x86_64 target="$t" 2>&1 | tail -12
done
