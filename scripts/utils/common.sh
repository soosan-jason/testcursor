#!/usr/bin/env bash
# =============================================================================
# common.sh - 공통 유틸리티 함수 모음
# =============================================================================

# 색상 코드
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# 로그 레벨
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# -----------------------------------------------------------------------------
# 로깅 함수
# -----------------------------------------------------------------------------
log_debug() { [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_DEBUG ]] && echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[DEBUG]${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_info()  { [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_INFO  ]] && echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[INFO] ${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_warn()  { [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_WARN  ]] && echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN] ${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_error() { [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_ERROR ]] && echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }

# -----------------------------------------------------------------------------
# 설정 파일 로드
# 사용법: load_config /path/to/service.conf
# -----------------------------------------------------------------------------
load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "설정 파일을 찾을 수 없음: $config_file"
        return 1
    fi
    # 주석(#)과 빈 줄을 제외하고 key=value 형식 소스
    # shellcheck disable=SC1090
    source <(grep -v '^\s*#' "$config_file" | grep -v '^\s*$')
    log_debug "설정 파일 로드 완료: $config_file"
}

# -----------------------------------------------------------------------------
# 날짜/시간 헬퍼
# -----------------------------------------------------------------------------
today()     { date '+%Y%m%d'; }
now()       { date '+%Y%m%d_%H%M%S'; }
yesterday() { date -d 'yesterday' '+%Y%m%d'; }

# -----------------------------------------------------------------------------
# 디렉토리 안전 생성
# -----------------------------------------------------------------------------
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { log_error "디렉토리 생성 실패: $dir"; return 1; }
        log_debug "디렉토리 생성: $dir"
    fi
}

# -----------------------------------------------------------------------------
# 파일 크기 (bytes)
# -----------------------------------------------------------------------------
file_size() {
    local f="$1"
    [[ -f "$f" ]] && stat -c%s "$f" || echo 0
}

# -----------------------------------------------------------------------------
# 사람이 읽기 쉬운 파일 크기 출력
# -----------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN{
        suffix[0]="B"; suffix[1]="KB"; suffix[2]="MB"; suffix[3]="GB"; suffix[4]="TB"
        i=0; while(b>=1024 && i<4){b/=1024; i++}
        printf "%.2f %s\n", b, suffix[i]
    }'
}

# -----------------------------------------------------------------------------
# 체크섬 생성 (SHA256)
# -----------------------------------------------------------------------------
generate_checksum() {
    local file="$1"
    sha256sum "$file" > "${file}.sha256"
    log_debug "체크섬 생성: ${file}.sha256"
}

# -----------------------------------------------------------------------------
# 체크섬 검증
# -----------------------------------------------------------------------------
verify_checksum() {
    local file="$1"
    local checksum_file="${file}.sha256"
    if [[ ! -f "$checksum_file" ]]; then
        log_error "체크섬 파일 없음: $checksum_file"
        return 1
    fi
    sha256sum -c "$checksum_file" --status && {
        log_info "체크섬 검증 성공: $file"
        return 0
    } || {
        log_error "체크섬 검증 실패: $file"
        return 1
    }
}

# -----------------------------------------------------------------------------
# 오래된 파일 정리 (보존 기간 초과)
# 사용법: cleanup_old_files /backup/dir 30  (30일 이전 삭제)
# -----------------------------------------------------------------------------
cleanup_old_files() {
    local dir="$1"
    local retention_days="${2:-30}"
    log_info "오래된 백업 정리 시작: $dir (보존: ${retention_days}일)"
    find "$dir" -maxdepth 1 -type f -mtime "+${retention_days}" -print -delete | \
        while read -r f; do log_info "삭제: $f"; done
    find "$dir" -maxdepth 1 -type d -mtime "+${retention_days}" -empty -print -delete | \
        while read -r d; do log_info "빈 디렉토리 삭제: $d"; done
}

# -----------------------------------------------------------------------------
# 압축 함수 (tar.gz, 선택적 openssl 암호화)
# -----------------------------------------------------------------------------
compress_files() {
    local src="$1"        # 압축할 경로
    local dest="$2"       # 출력 파일 경로 (*.tar.gz)
    local encrypt="${3:-false}"  # 암호화 여부
    local passphrase="${4:-}"    # 암호화 패스프레이즈

    log_info "압축 시작: $src -> $dest"
    tar -czf "$dest" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null || {
        log_error "압축 실패: $src"
        return 1
    }

    if [[ "$encrypt" == "true" && -n "$passphrase" ]]; then
        local enc_dest="${dest}.enc"
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -in "$dest" -out "$enc_dest" -pass "pass:${passphrase}" && {
            rm -f "$dest"
            mv "$enc_dest" "$dest"
            log_info "암호화 완료: $dest"
        } || {
            log_error "암호화 실패"
            return 1
        }
    fi

    generate_checksum "$dest"
    log_info "압축 완료 (크기: $(human_size "$(file_size "$dest")")): $dest"
}

# -----------------------------------------------------------------------------
# 복호화 + 압축 해제
# -----------------------------------------------------------------------------
decompress_files() {
    local src="$1"         # *.tar.gz (또는 암호화된)
    local dest_dir="$2"   # 압축 해제 경로
    local encrypt="${3:-false}"
    local passphrase="${4:-}"

    ensure_dir "$dest_dir"

    local working_file="$src"

    if [[ "$encrypt" == "true" && -n "$passphrase" ]]; then
        local dec_file="${src%.enc}"
        openssl enc -d -aes-256-cbc -pbkdf2 \
            -in "$src" -out "$dec_file" -pass "pass:${passphrase}" || {
            log_error "복호화 실패: $src"
            return 1
        }
        working_file="$dec_file"
    fi

    tar -xzf "$working_file" -C "$dest_dir" && {
        log_info "압축 해제 완료: $dest_dir"
    } || {
        log_error "압축 해제 실패: $working_file"
        return 1
    }

    [[ "$encrypt" == "true" ]] && rm -f "$working_file"
}

# -----------------------------------------------------------------------------
# 락 파일 관리 (중복 실행 방지)
# -----------------------------------------------------------------------------
LOCK_FILE=""

acquire_lock() {
    local lock_name="$1"
    LOCK_FILE="/tmp/backup_${lock_name}.lock"
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "이미 실행 중 (PID: $pid): $lock_name"
            return 1
        fi
        log_warn "오래된 락 파일 제거: $LOCK_FILE"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    log_debug "락 획득: $LOCK_FILE"
}

release_lock() {
    [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE" && \
        log_debug "락 해제: $LOCK_FILE"
}

# 스크립트 종료 시 자동 락 해제
trap release_lock EXIT

# -----------------------------------------------------------------------------
# 실행 결과 요약 구조체 (연관 배열)
# -----------------------------------------------------------------------------
declare -A BACKUP_RESULTS=()

record_result() {
    local service="$1"
    local status="$2"   # SUCCESS | FAILED | SKIPPED
    local message="${3:-}"
    BACKUP_RESULTS["$service"]="${status}|${message}"
}

print_results() {
    echo ""
    echo "======================================================"
    echo " 백업 결과 요약 - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    local success=0 failed=0 skipped=0
    for service in "${!BACKUP_RESULTS[@]}"; do
        local entry="${BACKUP_RESULTS[$service]}"
        local status="${entry%%|*}"
        local msg="${entry##*|}"
        case "$status" in
            SUCCESS) echo -e "  ${GREEN}✔${NC} $service - $msg"; ((success++)) ;;
            FAILED)  echo -e "  ${RED}✘${NC} $service - $msg"; ((failed++)) ;;
            SKIPPED) echo -e "  ${YELLOW}⊘${NC} $service - $msg"; ((skipped++)) ;;
        esac
    done
    echo "------------------------------------------------------"
    echo "  성공: $success  실패: $failed  건너뜀: $skipped"
    echo "======================================================"
    return $failed
}
