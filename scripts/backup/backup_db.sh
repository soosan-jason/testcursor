#!/usr/bin/env bash
# =============================================================================
# backup_db.sh - DB 백업 모듈 (MySQL/MariaDB/PostgreSQL/MongoDB)
# =============================================================================
# 사용법: source backup_db.sh && backup_database
# 필요 변수: DB_TYPE, DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAMES
#            SERVICE_NAME, LOCAL_TMP_DIR, SFTP_REMOTE_PATH

backup_database() {
    local service="$SERVICE_NAME"
    local db_type="${DB_TYPE:-mysql}"
    local date_str
    date_str=$(today)
    local ts
    ts=$(now)

    log_info "[$service] DB 백업 시작 (타입: $db_type)"

    local staging_dir="${LOCAL_TMP_DIR}/${service}/db/${date_str}"
    ensure_dir "$staging_dir"

    local remote_dir="${SFTP_REMOTE_PATH}/db"

    local success=0 failed=0

    case "$db_type" in
        mysql|mariadb)
            _backup_mysql "$staging_dir" "$remote_dir" "$ts"
            ;;
        postgresql|postgres)
            _backup_postgresql "$staging_dir" "$remote_dir" "$ts"
            ;;
        mongodb|mongo)
            _backup_mongodb "$staging_dir" "$remote_dir" "$ts"
            ;;
        *)
            log_error "[$service] 지원하지 않는 DB 타입: $db_type"
            return 1
            ;;
    esac

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "[$service] DB 백업 완료"
    else
        log_error "[$service] DB 백업 실패"
    fi
    return $exit_code
}

# -----------------------------------------------------------------------------
# MySQL / MariaDB 백업
# -----------------------------------------------------------------------------
_backup_mysql() {
    local staging_dir="$1"
    local remote_dir="$2"
    local ts="$3"
    local service="$SERVICE_NAME"

    # mysqldump 존재 확인
    if ! command -v mysqldump &>/dev/null; then
        log_error "mysqldump 명령어를 찾을 수 없음"
        return 1
    fi

    # DB 목록 결정 (지정 없으면 전체)
    local db_list
    if [[ -z "${DB_NAMES:-}" ]]; then
        log_info "[$service] 전체 DB 목록 조회 중..."
        db_list=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
            -u "$DB_USER" -p"${DB_PASS}" \
            --batch --skip-column-names \
            -e "SHOW DATABASES;" 2>/dev/null | \
            grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
    else
        db_list="$DB_NAMES"
    fi

    if [[ -z "$db_list" ]]; then
        log_warn "[$service] 백업할 DB 없음"
        return 0
    fi

    local all_ok=true
    for db in $db_list; do
        log_info "[$service] MySQL 덤프: $db"
        local dump_file="${staging_dir}/${service}_mysql_${db}_${ts}.sql"
        local archive_file="${dump_file}.tar.gz"

        local extra_opts="${DB_EXTRA_OPTS:---single-transaction --routines --triggers}"
        local exclude_opts=""
        for tbl in ${DB_EXCLUDE_TABLES:-}; do
            exclude_opts+=" --ignore-table=${db}.${tbl}"
        done

        # 덤프 실행
        if MYSQL_PWD="${DB_PASS}" mysqldump \
            -h "$DB_HOST" -P "$DB_PORT" \
            -u "$DB_USER" \
            $extra_opts \
            $exclude_opts \
            "$db" > "$dump_file" 2>/dev/null; then

            # 덤프 파일 크기 확인
            local size
            size=$(file_size "$dump_file")
            if [[ $size -lt 100 ]]; then
                log_error "[$service] MySQL 덤프 파일 비어있음: $db ($size bytes)"
                rm -f "$dump_file"
                all_ok=false
                continue
            fi

            # 압축 (선택적 암호화)
            compress_files "$dump_file" "$archive_file" \
                "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}"
            rm -f "$dump_file"

            # SFTP 업로드
            sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
                log_error "[$service] MySQL 업로드 실패: $db"
                all_ok=false
                continue
            }

            log_info "[$service] MySQL 백업 성공: $db ($(human_size "$(file_size "$archive_file")"))"
            rm -f "$archive_file" "${archive_file}.sha256"
        else
            log_error "[$service] MySQL 덤프 실패: $db"
            rm -f "$dump_file"
            all_ok=false
        fi
    done

    $all_ok && return 0 || return 1
}

# -----------------------------------------------------------------------------
# PostgreSQL 백업
# -----------------------------------------------------------------------------
_backup_postgresql() {
    local staging_dir="$1"
    local remote_dir="$2"
    local ts="$3"
    local service="$SERVICE_NAME"

    if ! command -v pg_dump &>/dev/null; then
        log_error "pg_dump 명령어를 찾을 수 없음"
        return 1
    fi

    # PGPASSFILE 설정
    if [[ -n "${PGPASSFILE:-}" ]]; then
        export PGPASSFILE
    elif [[ -n "${DB_PASS:-}" ]]; then
        export PGPASSWORD="$DB_PASS"
    fi

    local db_list="${DB_NAMES:-}"
    if [[ -z "$db_list" ]]; then
        log_info "[$service] PostgreSQL 전체 DB 목록 조회 중..."
        db_list=$(psql -h "$DB_HOST" -p "$DB_PORT" \
            -U "$DB_USER" -t -A \
            -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres');" 2>/dev/null)
    fi

    local all_ok=true
    for db in $db_list; do
        log_info "[$service] PostgreSQL 덤프: $db"
        local dump_file="${staging_dir}/${service}_pg_${db}_${ts}.dump"
        local archive_file="${dump_file}.tar.gz"

        if pg_dump \
            -h "$DB_HOST" -p "$DB_PORT" \
            -U "$DB_USER" \
            -Fc \
            ${DB_EXTRA_OPTS:---no-password --verbose} \
            "$db" > "$dump_file" 2>/dev/null; then

            local size
            size=$(file_size "$dump_file")
            if [[ $size -lt 100 ]]; then
                log_error "[$service] PostgreSQL 덤프 비어있음: $db"
                rm -f "$dump_file"
                all_ok=false
                continue
            fi

            compress_files "$dump_file" "$archive_file" \
                "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}"
            rm -f "$dump_file"

            sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
                log_error "[$service] PostgreSQL 업로드 실패: $db"
                all_ok=false
                continue
            }

            log_info "[$service] PostgreSQL 백업 성공: $db ($(human_size "$(file_size "$archive_file")"))"
            rm -f "$archive_file" "${archive_file}.sha256"
        else
            log_error "[$service] PostgreSQL 덤프 실패: $db"
            rm -f "$dump_file"
            all_ok=false
        fi
    done

    unset PGPASSWORD
    $all_ok && return 0 || return 1
}

# -----------------------------------------------------------------------------
# MongoDB 백업
# -----------------------------------------------------------------------------
_backup_mongodb() {
    local staging_dir="$1"
    local remote_dir="$2"
    local ts="$3"
    local service="$SERVICE_NAME"

    if ! command -v mongodump &>/dev/null; then
        log_error "mongodump 명령어를 찾을 수 없음"
        return 1
    fi

    local auth_opts=""
    if [[ -n "${DB_USER:-}" ]]; then
        auth_opts="--username $DB_USER --password ${DB_PASS} --authenticationDatabase ${DB_AUTH_DB:-admin}"
    fi

    local all_ok=true
    local dump_names="${DB_NAMES:-ALL}"

    for db in ${dump_names}; do
        local dump_dir="${staging_dir}/mongodump_${db}_${ts}"
        local archive_file="${staging_dir}/${service}_mongo_${db}_${ts}.tar.gz"

        local db_opt=""
        [[ "$db" != "ALL" ]] && db_opt="--db $db"

        log_info "[$service] MongoDB 덤프: ${db}"

        if mongodump \
            --host "$DB_HOST" --port "$DB_PORT" \
            $auth_opts $db_opt \
            ${DB_EXTRA_OPTS:---gzip} \
            --out "$dump_dir" 2>/dev/null; then

            compress_files "$dump_dir" "$archive_file" \
                "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}"
            rm -rf "$dump_dir"

            sftp_upload_with_checksum "$archive_file" "$remote_dir" || {
                log_error "[$service] MongoDB 업로드 실패: $db"
                all_ok=false
                continue
            }

            log_info "[$service] MongoDB 백업 성공: $db ($(human_size "$(file_size "$archive_file")"))"
            rm -f "$archive_file" "${archive_file}.sha256"
        else
            log_error "[$service] MongoDB 덤프 실패: $db"
            rm -rf "$dump_dir"
            all_ok=false
        fi
    done

    $all_ok && return 0 || return 1
}
