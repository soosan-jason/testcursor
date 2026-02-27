#!/usr/bin/env bash
# =============================================================================
# backup_web.sh - 웹/앱 모듈 백업 모듈
# =============================================================================
# 사용법: source backup_web.sh && backup_web_modules
# 필요 변수: WEB_SOURCE_DIRS (콜론 구분), WEB_EXCLUDE_PATTERNS
#            SERVICE_NAME, LOCAL_TMP_DIR, SFTP_REMOTE_PATH

backup_web_modules() {
    local service="$SERVICE_NAME"
    local date_str
    date_str=$(today)
    local ts
    ts=$(now)

    log_info "[$service] 웹/앱 모듈 백업 시작"

    local staging_dir="${LOCAL_TMP_DIR}/${service}/web/${date_str}"
    ensure_dir "$staging_dir"

    local remote_dir="${SFTP_REMOTE_PATH}/web"

    if [[ -z "${WEB_SOURCE_DIRS:-}" ]]; then
        log_warn "[$service] WEB_SOURCE_DIRS 미설정 - 웹 백업 건너뜀"
        return 0
    fi

    # 제외 옵션 구성
    local exclude_opts=""
    for pattern in ${WEB_EXCLUDE_PATTERNS:-}; do
        exclude_opts+=" --exclude=${pattern}"
    done

    local all_ok=true
    local idx=0

    # 콜론 구분 디렉토리 목록 순회
    IFS=':' read -ra source_dirs <<< "$WEB_SOURCE_DIRS"
    for src_dir in "${source_dirs[@]}"; do
        src_dir="${src_dir// /}"  # 공백 제거
        [[ -z "$src_dir" ]] && continue

        if [[ ! -e "$src_dir" ]]; then
            log_warn "[$service] 소스 경로 없음, 건너뜀: $src_dir"
            continue
        fi

        local dir_name
        dir_name=$(basename "$src_dir")
        local archive_name="${service}_web_${dir_name}_${ts}.tar.gz"
        local archive_file="${staging_dir}/${archive_name}"

        log_info "[$service] 웹 모듈 압축: $src_dir -> $archive_name"

        # tar 압축
        # shellcheck disable=SC2086
        tar -czf "$archive_file" \
            -C "$(dirname "$src_dir")" \
            "$(basename "$src_dir")" \
            $exclude_opts 2>/dev/null

        local exit_code=$?
        # 경고(파일 변경 등)는 무시, 실제 오류만 처리
        if [[ $exit_code -gt 1 ]]; then
            log_error "[$service] 웹 모듈 압축 실패: $src_dir (exit: $exit_code)"
            rm -f "$archive_file"
            all_ok=false
            continue
        fi

        local size
        size=$(file_size "$archive_file")
        if [[ $size -lt 10 ]]; then
            log_warn "[$service] 압축 파일이 너무 작음: $archive_file ($size bytes)"
        fi

        # 암호화 처리
        if [[ "${ENCRYPT_BACKUP:-false}" == "true" && -n "${ENCRYPT_PASSPHRASE:-}" ]]; then
            local enc_file="${archive_file}.enc"
            openssl enc -aes-256-cbc -salt -pbkdf2 \
                -in "$archive_file" -out "$enc_file" \
                -pass "pass:${ENCRYPT_PASSPHRASE}" && {
                rm -f "$archive_file"
                archive_file="$enc_file"
                log_debug "[$service] 암호화 완료: $archive_file"
            } || {
                log_error "[$service] 암호화 실패: $archive_file"
                rm -f "$archive_file"
                all_ok=false
                continue
            }
        fi

        generate_checksum "$archive_file"

        # SFTP 업로드
        sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
            log_error "[$service] 웹 모듈 업로드 실패: $src_dir"
            all_ok=false
        }

        log_info "[$service] 웹 모듈 백업 성공: $src_dir ($(human_size "$size"))"
        rm -f "$archive_file" "${archive_file}.sha256"
        ((idx++))
    done

    if [[ $idx -eq 0 ]]; then
        log_warn "[$service] 백업된 웹 모듈 없음"
        return 0
    fi

    $all_ok && {
        log_info "[$service] 웹/앱 모듈 백업 완료 (${idx}개)"
        return 0
    } || {
        log_error "[$service] 웹/앱 모듈 백업 일부 실패"
        return 1
    }
}
