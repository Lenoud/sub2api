#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_script="${test_dir}/../update-sub2api-with-rollback.sh"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

run_case() {
    local mode=$1 expected_status=$2 expected_image=$3 case_dir status=0
    case_dir="${work_dir}/${mode}"
    mkdir -p "$case_dir/bin" "$case_dir/state"
    cp "$source_script" "$case_dir/update-sub2api-with-rollback.sh"
    cp "${test_dir}/fixtures/update-sub2api/docker" "$case_dir/bin/docker"
    chmod +x "$case_dir/update-sub2api-with-rollback.sh" "$case_dir/bin/docker"
    printf 'services:\n  sub2api:\n    image: example/sub2api:old\n' > "$case_dir/docker-compose.yml"
    printf 'example/sub2api:old\n' > "$case_dir/state/active_image"

    PATH="${case_dir}/bin:${PATH}" \
    MOCK_MODE="$mode" MOCK_NEW_IMAGE=example/sub2api:new MOCK_STATE_DIR="$case_dir/state" \
        "$case_dir/update-sub2api-with-rollback.sh" example/sub2api:new \
        > "$case_dir/output.log" 2>&1 || status=$?

    if [[ $expected_status == success ]]; then
        [[ $status == 0 ]]
        grep -q '^    # image: example/sub2api:old$' "$case_dir/docker-compose.yml"
    else
        [[ $status != 0 ]]
        ! grep -q '^    # image: example/sub2api:old$' "$case_dir/docker-compose.yml"
    fi
    grep -q "^    image: ${expected_image}$" "$case_dir/docker-compose.yml"
    [[ $(cat "$case_dir/state/active_image") == "$expected_image" ]]
    [[ $(find "$case_dir" -maxdepth 1 -name 'docker-compose.yml.bak-update-*' | wc -l) == 1 ]]
    printf '%s: 通过\n' "$mode"
}

run_case healthy success example/sub2api:new
run_case start-fail failure example/sub2api:old
run_case unhealthy failure example/sub2api:old
