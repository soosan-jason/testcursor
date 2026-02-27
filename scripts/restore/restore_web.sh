#!/usr/bin/env bash
# =============================================================================
# restore_web.sh - 웹/앱 모듈 복원
# =============================================================================

restore_web_modules() {
    local backup_date="${1:-$(yesterday)}"
    local target_dir="${2:-}"  # 복원 대상 디렉토리 (비우면 원본 위치)
    local service="$SERVICE_NAME"

    log_info "[$service] 웹/앱 모듈 복원 시작 (기준일: $backup_date)"

    local remote_dir="${SFTP_REMOTE_BASE}/${service}/${backup_date}/web"
    local local_restore_dir="${LOCAL_TMP_DIR}/${service}/restore/web/${backup_date}"
    ensure_dir "$local_restore_dir"

    # 원격 파일 목록
    local remote_files
    remote_files=$(sftp_list "$remote_dir" 2>/dev/null | awk '{print $NF}' | grep '\.tar\.gz$')

    if [[ -z "$remote_files" ]]; then
        log_error "[$service] 웹 모듈 백업 파일 없음: ${remote_dir}"
        return 1
    fi

    local all_ok=true

    while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue

        log_info "[$service] 웹 모듈 다운로드: $fname"

        sftp_download "${remote_dir}/${fname}" "$local_restore_dir" || {
            log_error "[$service] 다운로드 실패: $fname"
            all_ok=false
            continue
        }
        sftp_download "${remote_dir}/${fname}.sha256" "$local_restore_dir" 2>/dev/null || true

        local local_file="${local_restore_dir}/${fname}"

        # 체크섬 검증
        if [[ -f "${local_file}.sha256" ]]; then
            verify_checksum "$local_file" || {
                log_error "[$service] 체크섬 불일치: $fname"
                all_ok=false
                continue
            }
        fi

        # 복원 대상 디렉토리 결정
        local restore_target
        if [[ -n "$target_dir" ]]; then
            restore_target="$target_dir"
        else
            # 원본 경로 추출: service_web_DIRNAME_TIMESTAMP.tar.gz
            local dir_name
            dir_name=$(echo "$fname" | sed -E "s/${service}_web_([^_]+)_.*/\1/")
            # WEB_SOURCE_DIRS에서 해당 디렉토리 찾기
            restore_target=""
            IFS=':' read -ra src_dirs <<< "${WEB_SOURCE_DIRS:-}"
            for sdir in "${src_dirs[@]}"; do
                if [[ "$(basename "$sdir")" == "$dir_name" ]]; then
                    restore_target="$(dirname "$sdir")"
                    break
                fi
            done
            # 못 찾으면 기본 경로
            restore_target="${restore_target:-/tmp/restored_web}"
        fi

        ensure_dir "$restore_target"

        log_info "[$service] 웹 모듈 압축 해제: $fname -> $restore_target"

        decompress_files "$local_file" "$restore_target" \
            "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}" || {
            log_error "[$service] 압축 해제 실패: $fname"
            all_ok=false
            rm -f "$local_file" "${local_file}.sha256"
            continue
        }

        log_info "[$service] 웹 모듈 복원 완료: $restore_target"
        rm -f "$local_file" "${local_file}.sha256"

    done <<< "$remote_files"

    $all_ok && {
        log_info "[$service] 웹/앱 모듈 복원 완료"
        return 0
    } || {
        log_error "[$service] 웹/앱 모듈 복원 일부 실패"
        return 1
    }
}

# -----------------------------------------------------------------------------
# 로그 복원 (참조/분석용)
# -----------------------------------------------------------------------------
restore_logs() {
    local backup_date="${1:-$(yesterday)}"
    local log_type="${2:-all}"   # app | os | all
    local restore_base="${3:-/tmp/restored_logs}"
    local service="$SERVICE_NAME"

    log_info "[$service] 로그 복원 시작 (기준일: $backup_date, 타입: $log_type)"

    local all_ok=true

    for ltype in app os; do
        [[ "$log_type" != "all" && "$log_type" != "$ltype" ]] && continue

        local remote_dir="${SFTP_REMOTE_BASE}/${service}/${backup_date}/logs/${ltype}"
        local local_restore_dir="${LOCAL_TMP_DIR}/${service}/restore/logs/${backup_date}/${ltype}"
        ensure_dir "$local_restore_dir"

        local remote_files
        remote_files=$(sftp_list "$remote_dir" 2>/dev/null | awk '{print $NF}' | grep '\.tar\.gz$')

        if [[ -z "$remote_files" ]]; then
            log_warn "[$service] ${ltype} 로그 백업 파일 없음: $remote_dir"
            continue
        fi

        while IFS= read -r fname; do
            [[ -z "$fname" ]] && continue

            sftp_download "${remote_dir}/${fname}" "$local_restore_dir" || {
                all_ok=false; continue
            }

            local local_file="${local_restore_dir}/${fname}"
            local restore_target="${restore_base}/${service}/${backup_date}/${ltype}"
            ensure_dir "$restore_target"

            decompress_files "$local_file" "$restore_target" \
                "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}" || {
                all_ok=false
            }

            rm -f "$local_file"
            log_info "[$service] ${ltype} 로그 복원: $restore_target"

        done <<< "$remote_files"
    done

    $all_ok && return 0 || return 1
}
