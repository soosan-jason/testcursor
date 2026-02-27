#!/usr/bin/env bash
# =============================================================================
# backup_logs.sh - 앱 로그 및 OS 로그 백업 모듈
# =============================================================================
# 사용법: source backup_logs.sh && backup_app_logs && backup_os_logs
# 필요 변수: APP_LOG_DIRS, APP_LOG_DAYS, APP_LOG_PATTERN
#            OS_LOG_DIRS, OS_LOG_FILES, OS_LOG_DAYS
#            SERVICE_NAME, LOCAL_TMP_DIR, SFTP_REMOTE_PATH

# -----------------------------------------------------------------------------
# 앱 로그 백업
# -----------------------------------------------------------------------------
backup_app_logs() {
    local service="$SERVICE_NAME"
    local date_str
    date_str=$(today)
    local ts
    ts=$(now)

    log_info "[$service] 앱 로그 백업 시작"

    if [[ -z "${APP_LOG_DIRS:-}" ]]; then
        log_warn "[$service] APP_LOG_DIRS 미설정 - 앱 로그 백업 건너뜀"
        return 0
    fi

    local staging_dir="${LOCAL_TMP_DIR}/${service}/app_logs/${date_str}"
    ensure_dir "$staging_dir"

    local remote_dir="${SFTP_REMOTE_PATH}/logs/app"
    local log_days="${APP_LOG_DAYS:-1}"
    local log_patterns="${APP_LOG_PATTERN:-*.log}"

    local collected_dir="${staging_dir}/collected"
    ensure_dir "$collected_dir"

    local file_count=0

    IFS=':' read -ra log_dirs <<< "$APP_LOG_DIRS"
    for log_dir in "${log_dirs[@]}"; do
        log_dir="${log_dir// /}"
        [[ -z "$log_dir" ]] && continue

        if [[ ! -d "$log_dir" ]]; then
            log_warn "[$service] 앱 로그 디렉토리 없음: $log_dir"
            continue
        fi

        local dest_sub="${collected_dir}$(dirname "$log_dir")"
        ensure_dir "$dest_sub"

        # 패턴별 파일 수집
        for pattern in $log_patterns; do
            while IFS= read -r -d '' log_file; do
                # 파일 크기 0이면 건너뜀
                [[ ! -s "$log_file" ]] && continue

                local rel_path="${log_file#/}"
                local dest_file="${collected_dir}/${rel_path}"
                ensure_dir "$(dirname "$dest_file")"
                cp "$log_file" "$dest_file" && ((file_count++))
                log_debug "[$service] 로그 수집: $log_file"
            done < <(find "$log_dir" -name "$pattern" \
                -mtime "-${log_days}" -type f -print0 2>/dev/null)
        done
    done

    if [[ $file_count -eq 0 ]]; then
        log_warn "[$service] 수집된 앱 로그 파일 없음"
        rm -rf "$collected_dir"
        return 0
    fi

    log_info "[$service] 앱 로그 ${file_count}개 수집 완료"

    local archive_file="${staging_dir}/${service}_app_logs_${ts}.tar.gz"
    compress_files "$collected_dir" "$archive_file" \
        "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}"
    rm -rf "$collected_dir"

    sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
        log_error "[$service] 앱 로그 업로드 실패"
        rm -f "$archive_file" "${archive_file}.sha256"
        return 1
    }

    log_info "[$service] 앱 로그 백업 완료 ($(human_size "$(file_size "$archive_file")"))"
    rm -f "$archive_file" "${archive_file}.sha256"
    return 0
}

# -----------------------------------------------------------------------------
# OS 로그 백업
# -----------------------------------------------------------------------------
backup_os_logs() {
    local service="$SERVICE_NAME"
    local date_str
    date_str=$(today)
    local ts
    ts=$(now)

    log_info "[$service] OS 로그 백업 시작"

    local staging_dir="${LOCAL_TMP_DIR}/${service}/os_logs/${date_str}"
    ensure_dir "$staging_dir"

    local remote_dir="${SFTP_REMOTE_PATH}/logs/os"
    local log_days="${OS_LOG_DAYS:-1}"
    local os_log_dir="${OS_LOG_DIRS:-/var/log}"
    local os_log_files="${OS_LOG_FILES:-syslog auth.log kern.log}"

    local collected_dir="${staging_dir}/os_collected"
    ensure_dir "$collected_dir"

    local file_count=0

    # 지정 파일 수집
    for log_file_name in $os_log_files; do
        IFS=':' read -ra log_dirs <<< "$os_log_dir"
        for log_dir in "${log_dirs[@]}"; do
            local full_path="${log_dir}/${log_file_name}"
            if [[ -f "$full_path" ]]; then
                cp "$full_path" "${collected_dir}/${log_file_name}" 2>/dev/null && \
                    ((file_count++)) && \
                    log_debug "[$service] OS 로그 수집: $full_path"
                break
            fi
            # 로테이트된 파일 (syslog.1 등) 포함
            for rotated in "${log_dir}/${log_file_name}".* ; do
                [[ ! -f "$rotated" ]] && continue
                local age_days
                age_days=$(( ( $(date +%s) - $(stat -c %Y "$rotated") ) / 86400 ))
                if [[ $age_days -le $log_days ]]; then
                    local dest_name="${log_file_name}.$(basename "$rotated" | sed "s/${log_file_name}\.//")"
                    cp "$rotated" "${collected_dir}/${dest_name}" 2>/dev/null && \
                        ((file_count++)) && \
                        log_debug "[$service] OS 로테이트 로그 수집: $rotated"
                fi
            done
        done
    done

    # journald 로그 수집 (systemd 환경)
    if command -v journalctl &>/dev/null; then
        local journal_file="${collected_dir}/journal_${date_str}.log"
        journalctl --since "$(date -d "${log_days} day ago" '+%Y-%m-%d')" \
            --until "now" \
            --no-pager -q > "$journal_file" 2>/dev/null
        [[ -s "$journal_file" ]] && ((file_count++)) || rm -f "$journal_file"
    fi

    if [[ $file_count -eq 0 ]]; then
        log_warn "[$service] 수집된 OS 로그 파일 없음"
        rm -rf "$collected_dir"
        return 0
    fi

    log_info "[$service] OS 로그 ${file_count}개 수집 완료"

    local archive_file="${staging_dir}/${service}_os_logs_${ts}.tar.gz"
    compress_files "$collected_dir" "$archive_file" \
        "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}"
    rm -rf "$collected_dir"

    sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
        log_error "[$service] OS 로그 업로드 실패"
        rm -f "$archive_file" "${archive_file}.sha256"
        return 1
    }

    log_info "[$service] OS 로그 백업 완료 ($(human_size "$(file_size "$archive_file")"))"
    rm -f "$archive_file" "${archive_file}.sha256"
    return 0
}
