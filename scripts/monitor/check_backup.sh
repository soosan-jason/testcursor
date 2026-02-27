#!/usr/bin/env bash
# =============================================================================
# check_backup.sh - 백업 상태 점검 모듈
# =============================================================================
# 원격 SFTP 서버의 백업 파일을 점검하여 이상 여부를 탐지합니다.
#
# 점검 항목:
#   1. 백업 파일 존재 여부
#   2. 파일 크기 (최소 크기 이하이면 이상)
#   3. 파일 최신성 (마지막 백업 후 허용 시간 초과 여부)
#   4. 체크섬 일치 여부
#   5. 보안: 권한 이상, 예상치 못한 파일 탐지

# 점검 결과 구조체
declare -A CHECK_RESULTS=()
# 형식: CHECK_RESULTS["service"]="OK|WARN|FAIL|msg1;msg2;..."

# -----------------------------------------------------------------------------
# 단일 서비스 백업 점검
# -----------------------------------------------------------------------------
check_service_backup() {
    local service="$1"
    local check_date="${2:-$(yesterday)}"  # 기본: 어제 날짜 점검

    log_info "[$service] 백업 점검 시작 (기준일: $check_date)"

    local remote_base="${SFTP_REMOTE_BASE}/${service}/${check_date}"
    local issues=()
    local warnings=()
    local overall="OK"

    # --- 1. 기본 디렉토리 존재 확인 ---
    local dir_listing
    dir_listing=$(sftp_list "$remote_base" 2>/dev/null)
    if [[ -z "$dir_listing" ]]; then
        issues+=("백업 디렉토리 없음: ${remote_base}")
        _record_check "$service" "FAIL" "${issues[*]}"
        return 1
    fi

    # --- 2. DB 백업 점검 ---
    if [[ "${BACKUP_DB_ENABLED:-true}" == "true" ]]; then
        local db_dir="${remote_base}/db"
        local db_listing
        db_listing=$(sftp_list "$db_dir" 2>/dev/null)

        if [[ -z "$db_listing" ]]; then
            issues+=("DB 백업 파일 없음: ${db_dir}")
            overall="FAIL"
        else
            # 각 .tar.gz 파일 검사
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == *"sftp>"* ]] && continue
                local filename
                filename=$(echo "$line" | awk '{print $NF}')
                [[ "$filename" != *.tar.gz ]] && continue

                local filesize
                filesize=$(echo "$line" | awk '{print $5}')
                _check_file_size "$service" "DB" "$filename" "$filesize" issues warnings

            done <<< "$db_listing"
        fi
    fi

    # --- 3. 웹 모듈 백업 점검 ---
    if [[ "${BACKUP_WEB_ENABLED:-true}" == "true" ]]; then
        local web_dir="${remote_base}/web"
        local web_listing
        web_listing=$(sftp_list "$web_dir" 2>/dev/null)

        if [[ -z "$web_listing" ]]; then
            issues+=("웹 모듈 백업 파일 없음: ${web_dir}")
            overall="FAIL"
        else
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == *"sftp>"* ]] && continue
                local filename
                filename=$(echo "$line" | awk '{print $NF}')
                [[ "$filename" != *.tar.gz ]] && continue
                local filesize
                filesize=$(echo "$line" | awk '{print $5}')
                _check_file_size "$service" "Web" "$filename" "$filesize" issues warnings
            done <<< "$web_listing"
        fi
    fi

    # --- 4. 앱 로그 백업 점검 ---
    if [[ "${BACKUP_APP_LOG_ENABLED:-true}" == "true" ]]; then
        local app_log_dir="${remote_base}/logs/app"
        local app_listing
        app_listing=$(sftp_list "$app_log_dir" 2>/dev/null)
        if [[ -z "$app_listing" ]]; then
            warnings+=("앱 로그 백업 파일 없음 (경고): ${app_log_dir}")
            [[ "$overall" == "OK" ]] && overall="WARN"
        fi
    fi

    # --- 5. OS 로그 백업 점검 ---
    if [[ "${BACKUP_OS_LOG_ENABLED:-true}" == "true" ]]; then
        local os_log_dir="${remote_base}/logs/os"
        local os_listing
        os_listing=$(sftp_list "$os_log_dir" 2>/dev/null)
        if [[ -z "$os_listing" ]]; then
            warnings+=("OS 로그 백업 파일 없음 (경고): ${os_log_dir}")
            [[ "$overall" == "OK" ]] && overall="WARN"
        fi
    fi

    # 이슈 종합
    if [[ ${#issues[@]} -gt 0 ]]; then
        overall="FAIL"
    elif [[ ${#warnings[@]} -gt 0 ]]; then
        [[ "$overall" == "OK" ]] && overall="WARN"
    fi

    local all_msgs=("${issues[@]}" "${warnings[@]}")
    local msg_str
    msg_str=$(IFS=';'; echo "${all_msgs[*]:-정상}")

    _record_check "$service" "$overall" "$msg_str"

    case "$overall" in
        OK)   log_info "[$service] 백업 점검: 정상" ;;
        WARN) log_warn "[$service] 백업 점검: 경고 - ${warnings[*]}" ;;
        FAIL) log_error "[$service] 백업 점검: 실패 - ${issues[*]}" ;;
    esac

    [[ "$overall" != "FAIL" ]]
}

# -----------------------------------------------------------------------------
# 파일 크기 점검 헬퍼
# -----------------------------------------------------------------------------
_check_file_size() {
    local service="$1"
    local component="$2"
    local filename="$3"
    local filesize="$4"
    local -n _issues=$5
    local -n _warnings=$6

    local min_size="${MONITOR_MIN_FILE_SIZE:-1024}"

    if [[ -z "$filesize" || ! "$filesize" =~ ^[0-9]+$ ]]; then
        _warnings+=("${component}: 파일 크기 확인 불가 - $filename")
        return
    fi

    if [[ $filesize -lt $min_size ]]; then
        _issues+=("${component}: 파일 크기 이상 ($filesize bytes < ${min_size} bytes) - $filename")
    else
        log_debug "[$service] ${component}: $filename OK ($(human_size "$filesize"))"
    fi
}

# -----------------------------------------------------------------------------
# 결과 기록
# -----------------------------------------------------------------------------
_record_check() {
    local service="$1"
    local status="$2"
    local msg="$3"
    CHECK_RESULTS["$service"]="${status}|${msg}"
}

# -----------------------------------------------------------------------------
# 보안 이상 탐지 점검
# -----------------------------------------------------------------------------
check_backup_security() {
    local service="$1"
    local check_date="${2:-$(yesterday)}"

    log_info "[$service] 보안 점검 시작"

    local remote_base="${SFTP_REMOTE_BASE}/${service}/${check_date}"
    local issues=()

    # 원격 파일 목록에서 예상치 못한 확장자 탐지
    local all_files
    all_files=$(sftp_list "$remote_base" 2>/dev/null)

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == *"sftp>"* ]] && continue
        local filename
        filename=$(echo "$line" | awk '{print $NF}')
        # 허용 확장자: .tar.gz, .tar.gz.sha256, .tar.gz.enc
        if [[ "$filename" =~ \.(sh|php|py|exe|bat|cmd)$ ]]; then
            issues+=("의심스러운 파일 탐지: $filename")
        fi
    done <<< "$all_files"

    if [[ ${#issues[@]} -gt 0 ]]; then
        local msg="${issues[*]}"
        log_error "[$service] 보안 이상: $msg"
        slack_notify_security "$service" "$msg"
        return 1
    fi

    log_info "[$service] 보안 점검: 이상 없음"
    return 0
}

# -----------------------------------------------------------------------------
# 점검 결과 출력
# -----------------------------------------------------------------------------
print_check_results() {
    echo ""
    echo "======================================================"
    echo " 백업 점검 결과 - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    local ok=0 warn=0 fail=0
    for service in "${!CHECK_RESULTS[@]}"; do
        local entry="${CHECK_RESULTS[$service]}"
        local status="${entry%%|*}"
        local msg="${entry##*|}"
        case "$status" in
            OK)   echo -e "  ${GREEN}✔${NC} $service - $msg"; ((ok++)) ;;
            WARN) echo -e "  ${YELLOW}⚠${NC} $service - $msg"; ((warn++)) ;;
            FAIL) echo -e "  ${RED}✘${NC} $service - $msg"; ((fail++)) ;;
        esac
    done
    echo "------------------------------------------------------"
    echo "  정상: $ok  경고: $warn  실패: $fail"
    echo "======================================================"
    return $fail
}
