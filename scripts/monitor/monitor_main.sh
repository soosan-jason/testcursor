#!/usr/bin/env bash
# =============================================================================
# monitor_main.sh - 백업 모니터링 메인 (일일 점검 + 리포트)
# =============================================================================
# 사용법:
#   ./monitor_main.sh                      어제 날짜 기준 전체 서비스 점검
#   ./monitor_main.sh --date 20240115      특정 날짜 점검
#   ./monitor_main.sh --service mysql-service  특정 서비스만 점검
#   ./monitor_main.sh --report-only        리포트 생성만 (점검 없음)
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
source "${SCRIPT_DIR}/check_backup.sh"

# 로그 설정
ensure_dir "${LOG_BASE_DIR:-/var/log/backup-system}"
LOG_FILE="${LOG_BASE_DIR}/monitor_$(today).log"

# 리포트 디렉토리
REPORT_DIR="${MONITOR_REPORT_DIR:-/var/log/backup-system/reports}"
ensure_dir "$REPORT_DIR"

# -----------------------------------------------------------------------------
# 옵션 파싱
# -----------------------------------------------------------------------------
CHECK_DATE=""
TARGET_SERVICE=""
REPORT_ONLY=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --date|-d)        CHECK_DATE="$2"; shift 2 ;;
            --service|-s)     TARGET_SERVICE="$2"; shift 2 ;;
            --report-only)    REPORT_ONLY=true; shift ;;
            --help|-h)        usage; exit 0 ;;
            *)                log_error "알 수 없는 옵션: $1"; usage; exit 1 ;;
        esac
    done

    # 기본 날짜: 어제
    CHECK_DATE="${CHECK_DATE:-$(yesterday)}"
}

usage() {
    cat <<EOF
사용법: $(basename "$0") [옵션]

옵션:
  --date YYYYMMDD     점검 기준 날짜 (기본: 어제)
  --service NAME      특정 서비스만 점검
  --report-only       리포트 생성만 (SFTP 점검 없음)
  --help, -h          도움말

예시:
  $(basename "$0")
  $(basename "$0") --date 20240115
  $(basename "$0") --service mysql-service
EOF
}

# -----------------------------------------------------------------------------
# 서비스 설정 파일 로드 및 점검
# -----------------------------------------------------------------------------
check_all_services() {
    local check_date="$1"
    local target_service="${2:-}"

    local configs=()
    while IFS= read -r -d '' cf; do
        configs+=("$cf")
    done < <(find "$BACKUP_CONFIG_DIR" -name "*.conf" -type f -print0 | sort -z)

    if [[ ${#configs[@]} -eq 0 ]]; then
        log_error "서비스 설정 파일을 찾을 수 없음: $BACKUP_CONFIG_DIR"
        return 1
    fi

    for config_file in "${configs[@]}"; do
        # 전역 설정 재로드 후 서비스 설정 적용
        source "$GLOBAL_CONFIG"
        load_config "$config_file"

        local service="${SERVICE_NAME:-unknown}"

        # 특정 서비스 필터
        if [[ -n "$target_service" && "$service" != "$target_service" ]]; then
            continue
        fi

        # 비활성화 서비스 건너뜀
        if [[ "${BACKUP_ENABLED:-true}" != "true" ]]; then
            log_info "[$service] 비활성화됨, 점검 건너뜀"
            _record_check "$service" "OK" "비활성화(BACKUP_ENABLED=false)"
            continue
        fi

        # 백업 상태 점검
        if [[ "$REPORT_ONLY" != "true" ]]; then
            check_service_backup "$service" "$check_date" || true
            check_backup_security "$service" "$check_date" || true
        else
            _record_check "$service" "OK" "리포트 전용 모드"
        fi
    done
}

# -----------------------------------------------------------------------------
# HTML 리포트 생성
# -----------------------------------------------------------------------------
generate_html_report() {
    local check_date="$1"
    local report_file="${REPORT_DIR}/backup_report_${check_date}.html"

    local ok_count=0 warn_count=0 fail_count=0
    local rows=""

    for service in "${!CHECK_RESULTS[@]}"; do
        local entry="${CHECK_RESULTS[$service]}"
        local status="${entry%%|*}"
        local msg="${entry##*|}"
        local row_class="success"
        local badge="<span class='badge success'>정상</span>"
        case "$status" in
            WARN) row_class="warning"; badge="<span class='badge warning'>경고</span>"; ((warn_count++)) ;;
            FAIL) row_class="danger";  badge="<span class='badge danger'>실패</span>";  ((fail_count++)) ;;
            OK)   ((ok_count++)) ;;
        esac
        # 메시지의 세미콜론을 <br>로 변환
        local msg_html
        msg_html=$(echo "$msg" | sed 's/;/<br>/g')
        rows+="<tr class='${row_class}'><td>${service}</td><td>${badge}</td><td>${msg_html}</td></tr>\n"
    done

    local total=$(( ok_count + warn_count + fail_count ))
    local report_ts
    report_ts=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "$report_file" <<HTML
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>백업 현황 리포트 - ${check_date}</title>
<style>
  body { font-family: 'Malgun Gothic', sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #333; }
  .summary { display: flex; gap: 16px; margin: 20px 0; }
  .summary-card { padding: 16px 24px; border-radius: 8px; color: white; font-size: 1.2em; text-align: center; min-width: 120px; }
  .card-total   { background: #607d8b; }
  .card-ok      { background: #4caf50; }
  .card-warn    { background: #ff9800; }
  .card-fail    { background: #f44336; }
  table { width: 100%; border-collapse: collapse; background: white; box-shadow: 0 2px 4px rgba(0,0,0,.1); }
  th { background: #37474f; color: white; padding: 12px; text-align: left; }
  td { padding: 10px 12px; border-bottom: 1px solid #eee; }
  tr.success { background: #f9fff9; }
  tr.warning  { background: #fffbf0; }
  tr.danger   { background: #fff5f5; }
  .badge { padding: 3px 10px; border-radius: 4px; font-size: .85em; color: white; }
  .badge.success { background: #4caf50; }
  .badge.warning { background: #ff9800; }
  .badge.danger  { background: #f44336; }
  .footer { color: #888; font-size: .85em; margin-top: 16px; }
</style>
</head>
<body>
<h1>&#128190; 백업 현황 리포트</h1>
<p>기준일: <strong>${check_date}</strong> &nbsp;|&nbsp; 생성: ${report_ts}</p>

<div class="summary">
  <div class="summary-card card-total">전체<br><strong>${total}</strong></div>
  <div class="summary-card card-ok">정상<br><strong>${ok_count}</strong></div>
  <div class="summary-card card-warn">경고<br><strong>${warn_count}</strong></div>
  <div class="summary-card card-fail">실패<br><strong>${fail_count}</strong></div>
</div>

<table>
  <thead>
    <tr><th>서비스</th><th>상태</th><th>상세</th></tr>
  </thead>
  <tbody>
    $(echo -e "$rows")
  </tbody>
</table>

<p class="footer">생성: Backup Monitor System | $(hostname)</p>
</body>
</html>
HTML

    log_info "HTML 리포트 생성 완료: $report_file"
    echo "$report_file"
}

# -----------------------------------------------------------------------------
# 텍스트 리포트 생성 (로컬 파일)
# -----------------------------------------------------------------------------
generate_text_report() {
    local check_date="$1"
    local report_file="${REPORT_DIR}/backup_report_${check_date}.txt"

    {
        echo "======================================================"
        echo " 백업 현황 리포트 - ${check_date}"
        echo " 생성: $(date '+%Y-%m-%d %H:%M:%S') | $(hostname)"
        echo "======================================================"
        local ok=0 warn=0 fail=0
        for service in "${!CHECK_RESULTS[@]}"; do
            local entry="${CHECK_RESULTS[$service]}"
            local status="${entry%%|*}"
            local msg="${entry##*|}"
            case "$status" in
                OK)   printf "  [OK  ] %-30s %s\n" "$service" "$msg"; ((ok++)) ;;
                WARN) printf "  [WARN] %-30s %s\n" "$service" "$msg"; ((warn++)) ;;
                FAIL) printf "  [FAIL] %-30s %s\n" "$service" "$msg"; ((fail++)) ;;
            esac
        done
        echo "------------------------------------------------------"
        echo "  정상: $ok  경고: $warn  실패: $fail"
        echo "======================================================"
    } > "$report_file"

    log_info "텍스트 리포트 생성: $report_file"
    echo "$report_file"
}

# -----------------------------------------------------------------------------
# 메인
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_info "======================================================"
    log_info " 백업 모니터링 시작 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info " 점검 기준일: $CHECK_DATE"
    log_info "======================================================"

    # SFTP 연결 테스트
    if [[ "$REPORT_ONLY" != "true" ]]; then
        sftp_test_connection || {
            log_error "SFTP 연결 실패 - 모니터링 중단"
            slack_notify_failure "BackupMonitor" "SFTP 연결 실패: ${SFTP_HOST}"
            exit 1
        }
    fi

    # 전체 서비스 점검
    check_all_services "$CHECK_DATE" "$TARGET_SERVICE"

    # 결과 집계
    local ok=0 warn=0 fail=0 details=""
    for service in "${!CHECK_RESULTS[@]}"; do
        local entry="${CHECK_RESULTS[$service]}"
        local status="${entry%%|*}"
        local msg="${entry##*|}"
        case "$status" in
            OK)   ((ok++));   details+="✔ ${service}\n" ;;
            WARN) ((warn++)); details+="⚠ ${service}: ${msg}\n" ;;
            FAIL) ((fail++)); details+="✘ ${service}: ${msg}\n" ;;
        esac
    done

    # 콘솔 출력
    print_check_results

    # 리포트 파일 생성
    local txt_report html_report
    txt_report=$(generate_text_report "$CHECK_DATE")
    html_report=$(generate_html_report "$CHECK_DATE")

    log_info "리포트 저장:"
    log_info "  텍스트: $txt_report"
    log_info "  HTML:   $html_report"

    # Slack 알림 (이상이 있거나 모든 결과 전송 설정일 때)
    if [[ $fail -gt 0 || $warn -gt 0 ]] || \
       [[ "${SLACK_NOTIFY_ON_FAILURE_ONLY:-true}" != "true" ]]; then
        slack_send_daily_report \
            "$CHECK_DATE" \
            "$ok" "$fail" "$warn" \
            "$(echo -e "$details")"
    fi

    # 오래된 리포트 정리 (30일 이상)
    find "$REPORT_DIR" -name "backup_report_*.txt" -mtime +30 -delete
    find "$REPORT_DIR" -name "backup_report_*.html" -mtime +30 -delete

    log_info "======================================================"
    log_info " 백업 모니터링 완료 - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "======================================================"

    [[ $fail -eq 0 ]]
}

main "$@"
