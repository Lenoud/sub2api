#!/usr/bin/env bash

set -Eeuo pipefail

readonly service=sub2api
readonly health_url=http://localhost:8080/health
readonly startup_timeout=30
readonly compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly compose_file="${compose_dir}/docker-compose.yml"

backup_file=
next_file=
rollback_required=0
old_image=

log() {
    printf '%s\n' "$*" >&2
}

container_ready() {
    local container_id=$1 expected_image=$2 actual_image running

    running=$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null) || return 1
    [[ $running == true ]] || return 1
    actual_image=$(docker inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null) || return 1
    [[ $actual_image == "$expected_image" ]] || return 1
    timeout --kill-after=1s 3s docker exec "$container_id" \
        wget -q -T 2 -O /dev/null "$health_url" >/dev/null 2>&1
}

wait_for_ready() {
    local expected_image=$1 deadline=$2 container_id

    while :; do
        container_id=$(docker compose -f "$compose_file" ps -q "$service" 2>/dev/null) || container_id=
        if [[ -n $container_id ]] && container_ready "$container_id" "$expected_image"; then
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            return 1
        fi
        sleep 1
    done
}

on_exit() {
    local result=$? restore_file deadline
    trap - EXIT
    set +e

    if (( rollback_required )); then
        log "新版本未在 ${startup_timeout} 秒内就绪，正在回退到 ${old_image}"
        restore_file=$(mktemp "${compose_dir}/.docker-compose.rollback.XXXXXXXX")
        if [[ -n $restore_file ]] && cp -p -- "$backup_file" "$restore_file" && \
            mv -f -- "$restore_file" "$compose_file"; then
            if timeout --kill-after=5s 30s docker compose -f "$compose_file" up -d --no-deps --pull never "$service"; then
                deadline=$(( $(date +%s) + startup_timeout ))
                if wait_for_ready "$old_image" "$deadline"; then
                    log "已恢复旧镜像，健康检查通过；原 Compose 备份：${backup_file}"
                else
                    log "严重：已恢复旧 Compose，但旧版本未通过健康检查，请立即检查服务。"
                fi
            else
                log "严重：已恢复旧 Compose，但重建旧容器失败，请立即检查服务。"
            fi
        else
            log "严重：恢复 Compose 文件失败；原文件备份：${backup_file}"
        fi
    fi

    [[ -z $next_file ]] || rm -f -- "$next_file"
    [[ -z ${restore_file:-} ]] || rm -f -- "$restore_file"
    exit "$result"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $# == 1 && $1 == --help ]]; then
    log "用法：$(basename "$0") <具体版本的镜像引用>"
    exit 0
fi
if [[ $# != 1 ]]; then
    log "用法：$(basename "$0") <具体版本的镜像引用>"
    exit 2
fi

new_image=$1
if [[ ! $new_image =~ ^[A-Za-z0-9._:/@-]+$ || $new_image == *:latest ]]; then
    log "镜像引用无效，需使用明确版本的 tag。"
    exit 2
fi

for command_name in docker jq awk flock timeout; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        log "缺少命令：${command_name}"
        exit 2
    fi
done

cd -- "$compose_dir"
exec 9>"${compose_dir}/.sub2api-update.lock"
if ! flock -n 9; then
    log "已有更新正在进行。"
    exit 2
fi

docker compose -f "$compose_file" config --quiet
old_image=$(docker compose -f "$compose_file" config --format json | jq -er '.services.sub2api.image')
if [[ $new_image == "$old_image" ]]; then
    log "当前已经是 ${new_image}，无需更新。"
    exit 0
fi

old_container=$(docker compose -f "$compose_file" ps -q "$service")
if [[ -z $old_container ]] || ! container_ready "$old_container" "$old_image"; then
    log "当前版本未通过健康检查，不能作为可靠的回退目标。"
    exit 1
fi
docker image inspect "$old_image" >/dev/null

if ! docker image inspect "$new_image" >/dev/null 2>&1; then
    log "预先拉取新镜像：${new_image}"
    docker pull "$new_image"
fi

backup_file="${compose_file}.bak-update-$(date +%Y%m%dT%H%M%S)-$$"
cp -p -- "$compose_file" "$backup_file"
next_file=$(mktemp "${compose_dir}/.docker-compose.next.XXXXXXXX")

awk -v new_image="$new_image" '
    /^  sub2api:[[:space:]]*$/ { in_service = 1; service_count++; print; next }
    in_service && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_service = 0 }
    in_service && /^    image:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
        image_count++
        sub(/^    /, "    # ")
        print
        print "    image: " new_image
        next
    }
    { print }
    END { if (service_count != 1 || image_count != 1) exit 1 }
' "$compose_file" > "$next_file"
chmod --reference="$compose_file" "$next_file"
docker compose -f "$next_file" config --quiet
resolved_image=$(docker compose -f "$next_file" config --format json | jq -er '.services.sub2api.image')
if [[ $resolved_image != "$new_image" ]]; then
    log "Compose 中解析出的镜像与目标镜像不一致。"
    exit 1
fi

rollback_required=1
mv -f -- "$next_file" "$compose_file"
next_file=

log "开始更新 ${service}：${old_image} -> ${new_image}"
log "自动回退只恢复 Compose 与应用镜像，不撤销数据库迁移。"
deadline=$(( $(date +%s) + startup_timeout ))
if ! timeout --kill-after=5s "${startup_timeout}s" docker compose -f "$compose_file" \
    up -d --no-deps --pull never "$service"; then
    log "新版本启动命令失败。"
    exit 1
fi

if ! wait_for_ready "$new_image" "$deadline"; then
    log "新版本健康检查超时。"
    exit 1
fi

rollback_required=0
log "更新成功，${service} 健康检查通过；旧 Compose 备份：${backup_file}"
