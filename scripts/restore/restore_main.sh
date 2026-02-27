#!/usr/bin/env bash
# =============================================================================
# restore_main.sh - 복원 오케스트레이터 (메인 진입점)
# =============================================================================
# 사용법:
#   ./restore_main.sh --service mysql-service --date 20240115
#   ./restore_main.sh --service mysql-service --date 20240115 --component db
#   ./restore_main.sh --service mysql-service --date 20240115 --db myapp_db
#   ./restore_main.sh --list --service mysql-service   이용 가능한 백업 목록
#
# 주의:
#   - 복원은 기존 데이터를 덮어씁니다!
#   - --force 옵션 없이는 확인 프롬프트가 표시됩니다.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

GLOBAL_CONFIG="${GLOBAL_CONFIG:-${PROJECT_ROOT}/config/global.conf}"
BACKUP_CONFIG_DIR="${BACKUP_CONFIG_DIR:-${PROJECT_ROOT}/config/services}"

source "${SCRIPT_DIR}/../utils/common.sh"
source "$GLOBAL_CONFIG"
source "${SCRIPT_DIR}/../utils/slack_notify.sh"
source "${SCRIPT_DIR}/../utils/sftp_helper.sh"
source "${SCRIPT_DIR}/restore_db.sh"
source "${SCRIPT_DIR}/restore_web.sh"

ensure_dir "${LOG_BASE_DIR:-/var/log/backup-system}"
LOG_FILE="${LOG_BASE_DIR}/restore_$(now).log"

# -----------------------------------------------------------------------------
# 옵션 파싱
# -----------------------------------------------------------------------------
TARGET_SERVICE=""
BACKUP_DATE=""
COMPONENT="all"   # all | db | web | logs
TARGET_DB=""
TARGET_DIR=""
FORCE=false
LIST_MODE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service|-s)    TARGET_SERVICE="$2"; shift 2 ;;
            --date|-d)       BACKUP_DATE="$2"; shift 2 ;;
            --component|-c)  COMPONENT="$2"; shift 2 ;;
            --db)            TARGET_DB="$2"; shift 2 ;;
            --target-dir)    TARGET_DIR="$2"; shift 2 ;;
            --force|-f)      FORCE=true; shift ;;
            --list|-l)       LIST_MODE=true; shift ;;
            --help|-h)       usage; exit 0 ;;
            *)               log_error "알 수 없는 옵션: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$TARGET_SERVICE" ]]; then
        log_error "--service 옵션이 필요합니다"
        usage; exit 1
    fi

    if [[ "$LIST_MODE" == false && -z "$BACKUP_DATE" ]]; then
        log_error "--date 옵션이 필요합니다 (형식: YYYYMMDD)"
        usage; exit 1
    fi
}

usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션]

필수:
  --service, -s NAME      복원할 서비스명
  --date, -d YYYYMMDD     복원 기준 백업 날짜

선택:
  --component, -c TYPE    복원 대상 (all|db|web|logs, 기본: all)
  --db DBNAME             특정 DB만 복원 (DB 복원 시)
  --target-dir PATH       복원 대상 경로 (기본: 원본 경로)
  --force, -f             확인 없이 바로 실행
  --list, -l              이용 가능한 백업 날짜 목록 조회
  --help, -h              도움말

예시:
  # 전체 복원
  $(basename "$0") --service mysql-service --date 20240115

  # DB만 복원
  $(basename "$0") --service mysql-service --date 20240115 --component db

  # 특정 DB만 복원
  $(basename "$0") --service mysql-service --date 20240115 --db myapp_db

  # 웹 모듈 복원 (특정 경로)
  $(basename "$0") --service mysql-service --date 20240115 --component web --target-dir /tmp/restore

  # 이용 가능한 백업 목록 조회
  $(basename "$0") --service mysql-service --list
EOF
}

# -----------------------------------------------------------------------------
# 이용 가능한 백업 목록 조회
# -----------------------------------------------------------------------------
list_available_backups() {
    local service="$1"
    local remote_base="${SFTP_REMOTE_BASE}/${service}"

    log_info "[$service] 이용 가능한 백업 목록 조회 중..."

    echo ""
    echo "======================================================"
    echo " 이용 가능한 백업 - 서비스: $service"
    echo "======================================================"

    local listing
    listing=$(sftp_list "$remote_base" 2>/dev/null)

    if [[ -z "$listing" ]]; then
        echo "  백업 없음 (경로: ${SFTP_HOST}:${remote_base})"
        echo "======================================================"
        return 1
    fi

    echo "$listing" | grep -E '^[0-9]{8}$' | sort -r | while IFS= read -r date_dir; do
        local date_fmt
        date_fmt=$(date -d "$date_dir" '+%Y년 %m월 %d일' 2>/dev/null || echo "$date_dir")
        echo "  - $date_dir ($date_fmt)"

        # 하위 컴포넌트 확인
        local sub_dirs
        sub_dirs=$(sftp_list "${remote_base}/${date_dir}" 2>/dev/null | awk '{print $NF}' | grep -v '^$')
        [[ -n "$sub_dirs" ]] && echo "      컴포넌트: $(echo "$sub_dirs" | tr '\n' ' ')"
    done || echo "  (날짜 디렉토리 없음)"

    echo "======================================================"
}

# -----------------------------------------------------------------------------
# 복원 확인 프롬프트
# -----------------------------------------------------------------------------
confirm_restore() {
    local service="$1"
    local date="$2"
    local component="$3"

    echo ""
    echo "======================================================"
    echo "  !! 경고: 복원 작업 확인 !!"
    echo "======================================================"
    echo "  서비스  : $service"
    echo "  백업일  : $date"
    echo "  대상    : $component"
    echo "  복원 후 기존 데이터가 덮어씌워집니다."
    echo "======================================================"
    echo -n "  계속하시겠습니까? [yes/N] > "
    read -r answer
    [[ "$answer" == "yes" ]] || {
        log_info "복원 취소"
        exit 0
    }
}

# -----------------------------------------------------------------------------
# 서비스 설정 로드
# -----------------------------------------------------------------------------
load_service_config() {
    local service="$1"
    local config_file

    # 설정 파일 탐색
    config_file=$(find "$BACKUP_CONFIG_DIR" -name "*.conf" -exec \
        grep -l "SERVICE_NAME=${service}" {} \; | head -1)

    if [[ -z "$config_file" ]]; then
        log_error "서비스 설정 파일을 찾을 수 없음: $service"
        return 1
    fi

    source "$GLOBAL_CONFIG"
    load_config "$config_file"
    log_info "설정 로드: $config_file"
}

# -----------------------------------------------------------------------------
# 메인
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"

    # 서비스 설정 로드
    load_service_config "$TARGET_SERVICE" || exit 1

    log_info "======================================================"
    log_info " 복원 시스템 시작 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info " 서비스: $TARGET_SERVICE"
    log_info "======================================================"

    # 목록 조회 모드
    if [[ "$LIST_MODE" == true ]]; then
        sftp_test_connection || { log_error "SFTP 연결 실패"; exit 1; }
        list_available_backups "$TARGET_SERVICE"
        exit 0
    fi

    # SFTP 연결 테스트
    sftp_test_connection || {
        log_error "SFTP 연결 실패: ${SFTP_HOST}"
        exit 1
    }

    # 복원 확인
    if [[ "$FORCE" != "true" ]]; then
        confirm_restore "$TARGET_SERVICE" "$BACKUP_DATE" "$COMPONENT"
    fi

    log_info "복원 시작: 서비스=$TARGET_SERVICE, 날짜=$BACKUP_DATE, 컴포넌트=$COMPONENT"

    local failed=false

    # --- DB 복원 ---
    if [[ "$COMPONENT" == "all" || "$COMPONENT" == "db" ]]; then
        if [[ "${BACKUP_DB_ENABLED:-true}" == "true" ]]; then
            restore_database "$BACKUP_DATE" "$TARGET_DB" || failed=true
        fi
    fi

    # --- 웹 모듈 복원 ---
    if [[ "$COMPONENT" == "all" || "$COMPONENT" == "web" ]]; then
        if [[ "${BACKUP_WEB_ENABLED:-true}" == "true" ]]; then
            restore_web_modules "$BACKUP_DATE" "$TARGET_DIR" || failed=true
        fi
    fi

    # --- 로그 복원 ---
    if [[ "$COMPONENT" == "all" || "$COMPONENT" == "logs" ]]; then
        local log_restore_dir="${TARGET_DIR:-/tmp/restored_logs}"
        restore_logs "$BACKUP_DATE" "all" "$log_restore_dir" || true
        # 로그 복원 실패는 전체 실패로 처리하지 않음 (참조용)
    fi

    # 임시 파일 정리
    rm -rf "${LOCAL_TMP_DIR:?}/${TARGET_SERVICE}/restore"

    if $failed; then
        log_error "복원 일부 실패"
        slack_notify_failure "$TARGET_SERVICE" "복원 일부 실패 (날짜: $BACKUP_DATE)"
        exit 1
    else
        log_info "======================================================"
        log_info " 복원 완료 - $(date '+%Y-%m-%d %H:%M:%S')"
        log_info "======================================================"
        slack_notify_restore "$TARGET_SERVICE" "$BACKUP_DATE" \
            "${RESTORE_TARGET_HOST:-localhost}"
        exit 0
    fi
}

main "$@"
