#!/usr/bin/env bash
# =============================================================================
# restore_db.sh - DB 복원 모듈 (MySQL/PostgreSQL/MongoDB)
# =============================================================================
# 사용법: source restore_db.sh && restore_database [backup_date] [db_name]

restore_database() {
    local backup_date="${1:-$(yesterday)}"
    local target_db="${2:-}"   # 특정 DB만 복원 (비우면 전체)
    local service="$SERVICE_NAME"
    local db_type="${DB_TYPE:-mysql}"

    log_info "[$service] DB 복원 시작 (타입: $db_type, 기준일: $backup_date)"

    local remote_dir="${SFTP_REMOTE_BASE}/${service}/${backup_date}/db"
    local local_restore_dir="${LOCAL_TMP_DIR}/${service}/restore/db/${backup_date}"
    ensure_dir "$local_restore_dir"

    # 원격 파일 목록 조회
    local remote_files
    remote_files=$(sftp_list "$remote_dir" 2>/dev/null | awk '{print $NF}' | grep '\.tar\.gz$')

    if [[ -z "$remote_files" ]]; then
        log_error "[$service] DB 백업 파일 없음: ${SFTP_HOST}:${remote_dir}"
        return 1
    fi

    # 복원 대상 파일 필터링
    local files_to_restore=()
    while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue
        if [[ -n "$target_db" ]]; then
            # 특정 DB 이름이 파일명에 포함된 경우만
            [[ "$fname" == *"_${target_db}_"* ]] && files_to_restore+=("$fname")
        else
            files_to_restore+=("$fname")
        fi
    done <<< "$remote_files"

    if [[ ${#files_to_restore[@]} -eq 0 ]]; then
        log_error "[$service] 복원할 DB 백업 파일 없음 (대상: ${target_db:-전체})"
        return 1
    fi

    local all_ok=true
    for fname in "${files_to_restore[@]}"; do
        log_info "[$service] 다운로드: $fname"

        # 체크섬 파일도 다운로드
        sftp_download "${remote_dir}/${fname}" "$local_restore_dir" || {
            log_error "[$service] 다운로드 실패: $fname"
            all_ok=false
            continue
        }
        sftp_download "${remote_dir}/${fname}.sha256" "$local_restore_dir" 2>/dev/null || true

        local local_file="${local_restore_dir}/${fname}"

        # 체크섬 검증
        if [[ -f "${local_file}.sha256" ]]; then
            verify_checksum "$local_file" || {
                log_error "[$service] 체크섬 불일치: $fname"
                all_ok=false
                continue
            }
        fi

        # 압축 해제
        local extract_dir="${local_restore_dir}/extracted_$(basename "$fname" .tar.gz)"
        decompress_files "$local_file" "$extract_dir" \
            "${ENCRYPT_BACKUP:-false}" "${ENCRYPT_PASSPHRASE:-}" || {
            log_error "[$service] 압축 해제 실패: $fname"
            all_ok=false
            continue
        }

        # DB 타입별 복원
        case "$db_type" in
            mysql|mariadb)
                _restore_mysql "$extract_dir" "$fname" || all_ok=false ;;
            postgresql|postgres)
                _restore_postgresql "$extract_dir" "$fname" || all_ok=false ;;
            mongodb|mongo)
                _restore_mongodb "$extract_dir" "$fname" || all_ok=false ;;
        esac

        # 임시 파일 정리
        rm -f "$local_file" "${local_file}.sha256"
        rm -rf "$extract_dir"
    done

    $all_ok && {
        log_info "[$service] DB 복원 완료"
        slack_notify_restore "$service" "$backup_date" "${RESTORE_TARGET_HOST:-localhost}"
        return 0
    } || {
        log_error "[$service] DB 복원 일부 실패"
        return 1
    }
}

# -----------------------------------------------------------------------------
# MySQL 복원
# -----------------------------------------------------------------------------
_restore_mysql() {
    local src_dir="$1"
    local archive_name="$2"
    local service="$SERVICE_NAME"

    # .sql 파일 탐색
    local sql_file
    sql_file=$(find "$src_dir" -name "*.sql" | head -1)
    if [[ -z "$sql_file" ]]; then
        log_error "[$service] MySQL 덤프 파일(.sql) 없음: $src_dir"
        return 1
    fi

    # DB 이름 추출 (파일명 패턴: service_mysql_DBNAME_TIMESTAMP.sql)
    local db_name
    db_name=$(basename "$sql_file" | sed -E 's/.*_mysql_([^_]+)_.*/\1/')

    local target_host="${RESTORE_TARGET_HOST:-$DB_HOST}"
    local target_user="${RESTORE_TARGET_DB_USER:-$DB_USER}"

    log_info "[$service] MySQL 복원: $db_name -> ${target_host}"

    # 대상 DB 생성 (없으면)
    MYSQL_PWD="${DB_PASS}" mysql \
        -h "$target_host" -P "${DB_PORT:-3306}" \
        -u "$target_user" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

    # 복원 실행
    if MYSQL_PWD="${DB_PASS}" mysql \
        -h "$target_host" -P "${DB_PORT:-3306}" \
        -u "$target_user" \
        "$db_name" < "$sql_file" 2>/dev/null; then
        log_info "[$service] MySQL 복원 성공: $db_name"
        return 0
    else
        log_error "[$service] MySQL 복원 실패: $db_name"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# PostgreSQL 복원
# -----------------------------------------------------------------------------
_restore_postgresql() {
    local src_dir="$1"
    local archive_name="$2"
    local service="$SERVICE_NAME"

    local dump_file
    dump_file=$(find "$src_dir" -name "*.dump" | head -1)
    if [[ -z "$dump_file" ]]; then
        log_error "[$service] PostgreSQL 덤프 파일(.dump) 없음: $src_dir"
        return 1
    fi

    local db_name
    db_name=$(basename "$dump_file" | sed -E 's/.*_pg_([^_]+)_.*/\1/')

    local target_host="${RESTORE_TARGET_HOST:-$DB_HOST}"
    local target_user="${RESTORE_TARGET_DB_USER:-$DB_USER}"

    [[ -n "${PGPASSFILE:-}" ]] && export PGPASSFILE
    [[ -n "${DB_PASS:-}" ]] && export PGPASSWORD="${DB_PASS}"

    log_info "[$service] PostgreSQL 복원: $db_name -> ${target_host}"

    # DB 생성 (없으면)
    psql -h "$target_host" -p "${DB_PORT:-5432}" \
        -U "$target_user" \
        -c "CREATE DATABASE \"${db_name}\";" 2>/dev/null || true

    # pg_restore 실행
    if pg_restore \
        -h "$target_host" -p "${DB_PORT:-5432}" \
        -U "$target_user" \
        --no-password \
        -d "$db_name" \
        --clean --if-exists \
        "$dump_file" 2>/dev/null; then
        log_info "[$service] PostgreSQL 복원 성공: $db_name"
        unset PGPASSWORD
        return 0
    else
        log_error "[$service] PostgreSQL 복원 실패: $db_name"
        unset PGPASSWORD
        return 1
    fi
}

# -----------------------------------------------------------------------------
# MongoDB 복원
# -----------------------------------------------------------------------------
_restore_mongodb() {
    local src_dir="$1"
    local archive_name="$2"
    local service="$SERVICE_NAME"

    local target_host="${RESTORE_TARGET_HOST:-$DB_HOST}"

    local auth_opts=""
    if [[ -n "${DB_USER:-}" ]]; then
        auth_opts="--username $DB_USER --password ${DB_PASS} --authenticationDatabase ${DB_AUTH_DB:-admin}"
    fi

    log_info "[$service] MongoDB 복원: $src_dir -> ${target_host}"

    if mongorestore \
        --host "$target_host" --port "${DB_PORT:-27017}" \
        $auth_opts \
        --drop \
        "$src_dir" 2>/dev/null; then
        log_info "[$service] MongoDB 복원 성공"
        return 0
    else
        log_error "[$service] MongoDB 복원 실패"
        return 1
    fi
}
