#!/usr/bin/env bash
# =============================================================================
# backup_main.sh - 백업 오케스트레이터 (메인 진입점)
# =============================================================================
# 사용법:
#   ./backup_main.sh [options] <service_config_file>
#   ./backup_main.sh --all               모든 서비스 백업
#   ./backup_main.sh service1.conf       특정 서비스 백업
#   ./backup_main.sh --dry-run all       드라이런 (실제 업로드 없음)
#
# 환경변수:
#   BACKUP_CONFIG_DIR  - 서비스 설정 디렉토리 (기본: ../../../config/services)
#   GLOBAL_CONFIG      - 전역 설정 파일 경로
# =============================================================================

set -euo pipefail

# 스크립트 절대 경로
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# 전역 설정 및 유틸 로드
GLOBAL_CONFIG="${GLOBAL_CONFIG:-${PROJECT_ROOT}/config/global.conf}"
BACKUP_CONFIG_DIR="${BACKUP_CONFIG_DIR:-${PROJECT_ROOT}/config/services}"

source "${SCRIPT_DIR}/../utils/common.sh"
source "${GLOBAL_CONFIG}"
source "${SCRIPT_DIR}/../utils/slack_notify.sh"
source "${SCRIPT_DIR}/../utils/sftp_helper.sh"
source "${SCRIPT_DIR}/backup_db.sh"
source "${SCRIPT_DIR}/backup_web.sh"
source "${SCRIPT_DIR}/backup_logs.sh"

# 로그 파일 설정
ensure_dir "${LOG_BASE_DIR:-/var/log/backup-system}"
LOG_FILE="${LOG_BASE_DIR}/backup_$(today).log"

# -----------------------------------------------------------------------------
# 옵션 파싱
# -----------------------------------------------------------------------------
DRY_RUN=false
ALL_SERVICES=false
TARGET_CONFIGS=()

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)   DRY_RUN=true; shift ;;
            --all|-a)       ALL_SERVICES=true; shift ;;
            --help|-h)      usage; exit 0 ;;
            *.conf)         TARGET_CONFIGS+=("$1"); shift ;;
            *)              log_error "알 수 없는 옵션: $1"; usage; exit 1 ;;
        esac
    done

    if [[ $ALL_SERVICES == false && ${#TARGET_CONFIGS[@]} -eq 0 ]]; then
        log_error "대상 서비스를 지정하세요. (--all 또는 <config>.conf)"
        usage
        exit 1
    fi
}

usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션] [서비스설정파일...]

옵션:
  --all, -a       모든 서비스 백업
  --dry-run, -n   드라이런 (백업 진행하지 않음, 설정 확인만)
  --help, -h      도움말

예시:
  $(basename "$0") --all
  $(basename "$0") mysql-service.conf postgresql-service.conf
  $(basename "$0") --dry-run --all
EOF
}

# -----------------------------------------------------------------------------
# 단일 서비스 백업 실행
# -----------------------------------------------------------------------------
run_service_backup() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "설정 파일 없음: $config_file"
        return 1
    fi

    # 전역 설정 재로드 후 서비스 설정 오버라이드
    source "$GLOBAL_CONFIG"
    load_config "$config_file"

    local service="${SERVICE_NAME:-unknown}"

    # 비활성화된 서비스 건너뜀
    if [[ "${BACKUP_ENABLED:-true}" != "true" ]]; then
        log_info "[$service] 비활성화됨, 건너뜀"
        record_result "$service" "SKIPPED" "BACKUP_ENABLED=false"
        return 0
    fi

    # 락 획득 (서비스별)
    acquire_lock "$service" || {
        log_warn "[$service] 이미 실행 중, 건너뜀"
        record_result "$service" "SKIPPED" "이미 실행 중"
        return 0
    }

    # 날짜 기반 원격 경로 구성
    local date_str
    date_str=$(today)
    SFTP_REMOTE_PATH="${SFTP_REMOTE_BASE}/${service}/${date_str}"

    # 로컬 스테이징 초기화
    ensure_dir "${LOCAL_TMP_DIR}/${service}"

    log_info "========================================================="
    log_info "[$service] 백업 시작 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "  설정: $config_file"
    log_info "  원격 경로: ${SFTP_HOST}:${SFTP_REMOTE_PATH}"
    log_info "========================================================="

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[$service] [드라이런] 실제 백업 건너뜀"
        record_result "$service" "SKIPPED" "드라이런 모드"
        release_lock
        return 0
    fi

    # SFTP 연결 테스트
    sftp_test_connection || {
        local msg="SFTP 연결 실패: ${SFTP_HOST}"
        log_error "[$service] $msg"
        record_result "$service" "FAILED" "$msg"
        slack_notify_failure "$service" "$msg"
        release_lock
        return 1
    }

    local start_time=$SECONDS
    local failed_components=()

    # --- DB 백업 ---
    if [[ "${BACKUP_DB_ENABLED:-true}" == "true" ]]; then
        backup_database || failed_components+=("DB")
    fi

    # --- 웹 모듈 백업 ---
    if [[ "${BACKUP_WEB_ENABLED:-true}" == "true" ]]; then
        backup_web_modules || failed_components+=("Web")
    fi

    # --- 앱 로그 백업 ---
    if [[ "${BACKUP_APP_LOG_ENABLED:-true}" == "true" ]]; then
        backup_app_logs || failed_components+=("AppLog")
    fi

    # --- OS 로그 백업 ---
    if [[ "${BACKUP_OS_LOG_ENABLED:-true}" == "true" ]]; then
        backup_os_logs || failed_components+=("OsLog")
    fi

    local elapsed=$(( SECONDS - start_time ))
    local duration="${elapsed}초"

    # 임시 파일 정리
    rm -rf "${LOCAL_TMP_DIR:?}/${service}"

    # 결과 기록
    if [[ ${#failed_components[@]} -eq 0 ]]; then
        local msg="모든 컴포넌트 성공 (소요: ${duration})"
        record_result "$service" "SUCCESS" "$msg"
        [[ "${SLACK_NOTIFY_ON_FAILURE_ONLY:-true}" != "true" ]] && \
            slack_notify_success "$service" "$msg"
        log_info "[$service] 백업 완료 - $msg"
    else
        local failed_str
        failed_str=$(IFS=','; echo "${failed_components[*]}")
        local msg="실패 컴포넌트: ${failed_str} (소요: ${duration})"
        record_result "$service" "FAILED" "$msg"
        slack_notify_failure "$service" "$msg"
        log_error "[$service] 백업 실패 - $msg"
        release_lock
        return 1
    fi

    release_lock
    return 0
}

# -----------------------------------------------------------------------------
# 메인 실행
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_info "======================================================"
    log_info " 백업 시스템 시작 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info " DRY_RUN: $DRY_RUN"
    log_info "======================================================"

    # 대상 설정 파일 목록 구성
    local configs=()
    if [[ $ALL_SERVICES == true ]]; then
        while IFS= read -r -d '' cf; do
            configs+=("$cf")
        done < <(find "$BACKUP_CONFIG_DIR" -name "*.conf" -type f -print0 | sort -z)
    else
        for cfg in "${TARGET_CONFIGS[@]}"; do
            if [[ -f "$cfg" ]]; then
                configs+=("$cfg")
            elif [[ -f "${BACKUP_CONFIG_DIR}/${cfg}" ]]; then
                configs+=("${BACKUP_CONFIG_DIR}/${cfg}")
            else
                log_error "설정 파일을 찾을 수 없음: $cfg"
            fi
        done
    fi

    if [[ ${#configs[@]} -eq 0 ]]; then
        log_error "실행할 서비스 설정이 없음"
        exit 1
    fi

    log_info "대상 서비스 수: ${#configs[@]}"

    # 각 서비스 순차 백업
    for config_file in "${configs[@]}"; do
        run_service_backup "$config_file" || true  # 단일 실패로 전체 중단 방지
    done

    # 전체 결과 출력
    print_results
    local exit_code=$?

    # 일별 리포트 전송 (실패가 있거나 항상 전송 설정일 때)
    local success_count=0 failed_count=0 skipped_count=0 details=""
    for service in "${!BACKUP_RESULTS[@]}"; do
        local entry="${BACKUP_RESULTS[$service]}"
        local status="${entry%%|*}"
        local msg="${entry##*|}"
        case "$status" in
            SUCCESS) ((success_count++)); details+="✔ ${service}: ${msg}\n" ;;
            FAILED)  ((failed_count++));  details+="✘ ${service}: ${msg}\n" ;;
            SKIPPED) ((skipped_count++)); details+="⊘ ${service}: ${msg}\n" ;;
        esac
    done

    if [[ $failed_count -gt 0 ]] || [[ "${SLACK_NOTIFY_ON_FAILURE_ONLY:-true}" != "true" ]]; then
        slack_send_daily_report \
            "$(date '+%Y-%m-%d')" \
            "$success_count" "$failed_count" "$skipped_count" \
            "$details"
    fi

    log_info "======================================================"
    log_info " 백업 시스템 종료 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "======================================================"

    exit $exit_code
}

main "$@"
