#!/usr/bin/env bash
# PostgreSQL quoting and failure-path regressions; only PHP CLI is required.
set -Eeuo pipefail
test_case='database test setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file=${1:-$tests_dir/../src/runtime/makedb.php}
command -v php >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
php -n -l "$source_file" >/dev/null

for fixture in special empty-password; do
    for scenario in created existing lookup-failure escape-failure create-failure; do
        test_case="$fixture credentials, $scenario database operation"
        status=0
        php -n "$tests_dir/makedb-check.php" "$source_file" "$scenario" "$fixture" \
            >"$work/output" 2>&1 || status=$?
        case "$scenario" in
            created|existing)
                [[ $status == 0 ]]
                grep -Fq 'PostgreSQL Database Created' "$work/output"
                ;;
            *)
                [[ $status == 1 ]]
                case "$scenario" in
                    lookup-failure) message='PostgreSQL Database Lookup Error' ;;
                    escape-failure) message='PostgreSQL Database Name Error' ;;
                    create-failure) message="PostgreSQL 'CREATE DATABASE' Error" ;;
                esac
                grep -Fq "$message" "$work/output"
                if grep -Fq 'PostgreSQL Database Created' "$work/output"; then
                    echo 'Database initialization reported success after a failure.' >&2
                    exit 1
                fi
                ;;
        esac
        if grep -Eq 'secret|password host=attacker|Fatal error|Warning:' "$work/output"; then
            echo 'Database initialization exposed credentials or an unhandled error.' >&2
            exit 1
        fi
    done
done
printf 'PostgreSQL database helper tests passed.\n'
