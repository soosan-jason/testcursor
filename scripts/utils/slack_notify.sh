#!/usr/bin/env bash
# =============================================================================
# slack_notify.sh - Slack 웹훅 알림 유틸리티
# =============================================================================
# 사용법:
#   source slack_notify.sh
#   slack_send_message "채널명" "메시지" "good|warning|danger"
#   slack_send_backup_report <결과_연관배열_이름>

SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_DEFAULT_CHANNEL="${SLACK_DEFAULT_CHANNEL:-#backup-alerts}"
SLACK_BOT_NAME="${SLACK_BOT_NAME:-BackupBot}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:floppy_disk:}"

# -----------------------------------------------------------------------------
# 기본 메시지 전송
# -----------------------------------------------------------------------------
slack_send() {
    local channel="${1:-$SLACK_DEFAULT_CHANNEL}"
    local text="$2"
    local color="${3:-good}"   # good | warning | danger | #RRGGBB

    if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
        echo "[SLACK] 웹훅 URL 미설정 - 메시지 건너뜀: $text"
        return 0
    fi

    local payload
    payload=$(cat <<EOF
{
    "channel": "${channel}",
    "username": "${SLACK_BOT_NAME}",
    "icon_emoji": "${SLACK_ICON_EMOJI}",
    "attachments": [
        {
            "color": "${color}",
            "text": ${text},
            "ts": $(date +%s)
        }
    ]
}
EOF
)

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK_URL")

    if [[ "$response" == "200" ]]; then
        log_debug "Slack 전송 성공 (채널: $channel)"
        return 0
    else
        log_warn "Slack 전송 실패 (HTTP: $response)"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 텍스트 JSON 이스케이프
# -----------------------------------------------------------------------------
json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"
}

# -----------------------------------------------------------------------------
# 백업 성공 알림
# -----------------------------------------------------------------------------
slack_notify_success() {
    local service="$1"
    local details="${2:-}"
    local msg
    msg=$(json_escape ":white_check_mark: *[백업 성공]* \`${service}\`\n${details}\n시각: $(date '+%Y-%m-%d %H:%M:%S')")
    slack_send "$SLACK_DEFAULT_CHANNEL" "$msg" "good"
}

# -----------------------------------------------------------------------------
# 백업 실패 알림 (즉시 알림용)
# -----------------------------------------------------------------------------
slack_notify_failure() {
    local service="$1"
    local reason="${2:-알 수 없는 오류}"
    local msg
    msg=$(json_escape ":x: *[백업 실패]* \`${service}\`\n원인: ${reason}\n시각: $(date '+%Y-%m-%d %H:%M:%S')\n담당자 확인 필요!")
    slack_send "$SLACK_DEFAULT_CHANNEL" "$msg" "danger"
}

# -----------------------------------------------------------------------------
# 경고 알림
# -----------------------------------------------------------------------------
slack_notify_warning() {
    local service="$1"
    local message="${2:-경고}"
    local msg
    msg=$(json_escape ":warning: *[백업 경고]* \`${service}\`\n${message}\n시각: $(date '+%Y-%m-%d %H:%M:%S')")
    slack_send "$SLACK_DEFAULT_CHANNEL" "$msg" "warning"
}

# -----------------------------------------------------------------------------
# 일별 종합 리포트 전송
# 사용법: slack_send_daily_report "날짜" 성공수 실패수 건너뜀수 "세부내역 문자열"
# -----------------------------------------------------------------------------
slack_send_daily_report() {
    local report_date="$1"
    local success_count="$2"
    local failed_count="$3"
    local skipped_count="$4"
    local details="$5"
    local total=$(( success_count + failed_count + skipped_count ))

    local color="good"
    local header_emoji=":white_check_mark:"
    if [[ $failed_count -gt 0 ]]; then
        color="danger"
        header_emoji=":rotating_light:"
    elif [[ $skipped_count -gt 0 ]]; then
        color="warning"
        header_emoji=":warning:"
    fi

    local msg
    msg=$(json_escape "${header_emoji} *일별 백업 현황 리포트* - ${report_date}

> 전체: ${total}건  |  :white_check_mark: 성공: ${success_count}  |  :x: 실패: ${failed_count}  |  :zzz: 건너뜀: ${skipped_count}

${details}")

    slack_send "$SLACK_DEFAULT_CHANNEL" "$msg" "$color"
}

# -----------------------------------------------------------------------------
# 복원 완료 알림
# -----------------------------------------------------------------------------
slack_notify_restore() {
    local service="$1"
    local backup_date="$2"
    local target="${3:-원본 서버}"
    local msg
    msg=$(json_escape ":recycle: *[복원 완료]* \`${service}\`\n백업 기준일: ${backup_date}\n복원 대상: ${target}\n시각: $(date '+%Y-%m-%d %H:%M:%S')")
    slack_send "$SLACK_DEFAULT_CHANNEL" "$msg" "#439FE0"
}

# -----------------------------------------------------------------------------
# 보안 이상 알림
# -----------------------------------------------------------------------------
slack_notify_security() {
    local check_name="$1"
    local message="$2"
    local msg
    msg=$(json_escape ":lock: *[보안 이상 감지]* \`${check_name}\`\n${message}\n시각: $(date '+%Y-%m-%d %H:%M:%S')\n즉시 점검 필요!")
    slack_send "${SLACK_SECURITY_CHANNEL:-$SLACK_DEFAULT_CHANNEL}" "$msg" "danger"
}
