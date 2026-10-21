#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Resolve configuration first, then generate complete image build contexts.
# Force refreshes download metadata; it is not a Docker build option.
targets=()
for argument; do
    case "$argument" in
        -f|--force) ;;
        -h|--help)
            echo 'Usage: ./generate.sh [--force] [SERIES | SERIES/STATE ...]'
            exit 0
            ;;
        *) targets+=("$argument") ;;
    esac
done
./src/build/versions.sh "$@"
./src/build/build.sh "${targets[@]}"
