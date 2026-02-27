#!/usr/bin/env bash
# =============================================================================
# sftp_helper.sh - SFTP 전송 유틸리티
# =============================================================================
# 필수 환경 변수:
#   SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_KEY_FILE 또는 SFTP_PASS
#   SFTP_REMOTE_BASE  - 원격 베이스 디렉토리 (예: /backup)

# -----------------------------------------------------------------------------
# SFTP 공통 옵션 구성
# -----------------------------------------------------------------------------
_sftp_opts() {
    local opts=(
        "-o StrictHostKeyChecking=no"
        "-o BatchMode=yes"
        "-o ConnectTimeout=${SFTP_TIMEOUT:-30}"
        "-P ${SFTP_PORT:-22}"
    )
    if [[ -n "${SFTP_KEY_FILE:-}" ]]; then
        opts+=("-i $SFTP_KEY_FILE")
    fi
    echo "${opts[*]}"
}

# -----------------------------------------------------------------------------
# SFTP 연결 테스트
# -----------------------------------------------------------------------------
sftp_test_connection() {
    local opts
    opts=$(_sftp_opts)

    log_info "SFTP 연결 테스트: ${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT:-22}"

    # shellcheck disable=SC2086
    if echo "exit" | sftp $opts "${SFTP_USER}@${SFTP_HOST}" > /dev/null 2>&1; then
        log_info "SFTP 연결 성공"
        return 0
    else
        log_error "SFTP 연결 실패: ${SFTP_USER}@${SFTP_HOST}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 원격 디렉토리 생성
# -----------------------------------------------------------------------------
sftp_mkdir() {
    local remote_dir="$1"
    local opts
    opts=$(_sftp_opts)

    log_debug "원격 디렉토리 생성: $remote_dir"
    # shellcheck disable=SC2086
    sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF > /dev/null 2>&1
-mkdir $remote_dir
EOF
    return 0  # 이미 존재해도 무시
}

# -----------------------------------------------------------------------------
# 파일 업로드
# 사용법: sftp_upload /local/file /remote/dir
# -----------------------------------------------------------------------------
sftp_upload() {
    local local_file="$1"
    local remote_dir="$2"
    local retry_max="${SFTP_RETRY:-3}"
    local retry_delay=2
    local opts
    opts=$(_sftp_opts)

    if [[ ! -f "$local_file" ]]; then
        log_error "업로드할 파일 없음: $local_file"
        return 1
    fi

    sftp_mkdir "$remote_dir"

    local attempt=0
    while [[ $attempt -lt $retry_max ]]; do
        ((attempt++))
        log_info "SFTP 업로드 시도 $attempt/$retry_max: $local_file -> ${SFTP_HOST}:${remote_dir}"

        # shellcheck disable=SC2086
        if sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF > /dev/null 2>&1
put $local_file $remote_dir/
EOF
        then
            log_info "업로드 성공: $(basename "$local_file")"
            return 0
        fi

        log_warn "업로드 실패, ${retry_delay}초 후 재시도..."
        sleep $retry_delay
        retry_delay=$(( retry_delay * 2 ))
    done

    log_error "SFTP 업로드 최종 실패: $local_file"
    return 1
}

# -----------------------------------------------------------------------------
# 체크섬 파일 포함 업로드
# -----------------------------------------------------------------------------
sftp_upload_with_checksum() {
    local local_file="$1"
    local remote_dir="$2"

    sftp_upload "$local_file" "$remote_dir" || return 1

    if [[ -f "${local_file}.sha256" ]]; then
        sftp_upload "${local_file}.sha256" "$remote_dir" || \
            log_warn "체크섬 파일 업로드 실패: ${local_file}.sha256"
    fi
}

# -----------------------------------------------------------------------------
# 원격 파일 목록 조회
# 사용법: sftp_list /remote/dir
# -----------------------------------------------------------------------------
sftp_list() {
    local remote_dir="$1"
    local opts
    opts=$(_sftp_opts)

    # shellcheck disable=SC2086
    sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF 2>/dev/null | grep -v "^sftp>" | grep -v "^$"
ls -la $remote_dir
EOF
}

# -----------------------------------------------------------------------------
# 파일 다운로드 (복원용)
# 사용법: sftp_download /remote/file /local/dir
# -----------------------------------------------------------------------------
sftp_download() {
    local remote_file="$1"
    local local_dir="$2"
    local retry_max="${SFTP_RETRY:-3}"
    local retry_delay=2
    local opts
    opts=$(_sftp_opts)

    ensure_dir "$local_dir"

    local attempt=0
    while [[ $attempt -lt $retry_max ]]; do
        ((attempt++))
        log_info "SFTP 다운로드 시도 $attempt/$retry_max: ${SFTP_HOST}:${remote_file} -> $local_dir"

        # shellcheck disable=SC2086
        if sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF > /dev/null 2>&1
get $remote_file $local_dir/
EOF
        then
            log_info "다운로드 성공: $(basename "$remote_file")"
            return 0
        fi

        log_warn "다운로드 실패, ${retry_delay}초 후 재시도..."
        sleep $retry_delay
        retry_delay=$(( retry_delay * 2 ))
    done

    log_error "SFTP 다운로드 최종 실패: $remote_file"
    return 1
}

# -----------------------------------------------------------------------------
# 원격 파일 존재 여부 확인
# -----------------------------------------------------------------------------
sftp_file_exists() {
    local remote_file="$1"
    local opts
    opts=$(_sftp_opts)

    # shellcheck disable=SC2086
    sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF 2>/dev/null | grep -q "$(basename "$remote_file")"
ls $(dirname "$remote_file")
EOF
}

# -----------------------------------------------------------------------------
# 원격 파일 크기 확인 (bytes)
# -----------------------------------------------------------------------------
sftp_file_size() {
    local remote_file="$1"
    local opts
    opts=$(_sftp_opts)

    # shellcheck disable=SC2086
    sftp $opts "${SFTP_USER}@${SFTP_HOST}" <<EOF 2>/dev/null | awk '{print $5}'
ls -la $remote_file
EOF
}
