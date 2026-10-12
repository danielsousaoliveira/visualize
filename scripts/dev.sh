#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
swift "$repo_root/scripts/quit-app.swift" com.danielsousaoliveira.visualize
bash "$repo_root/scripts/build-app.sh" --debug
open -n "$repo_root/build/visualize.app"
