# 시스템 아키텍처

## 전체 구조

```
[서비스 서버 A]  [서비스 서버 B]  [서비스 서버 C]
  MySQL           PostgreSQL        MongoDB + Node
     \                |                /
      \               |               /
       --------[SFTP 전송]----------
                      |
              [백업 서버 (SFTP)]
              /backup/
                ├── mysql-service/
                │   └── 20240115/
                │       ├── db/          # DB 덤프
                │       ├── web/         # 웹 소스
                │       └── logs/        # 로그
                │           ├── app/
                │           └── os/
                ├── postgresql-service/
                └── mongodb-service/
                      |
              [모니터링 스크립트]
              (backup 서버에서 실행)
                      |
               [Slack 알림 / HTML 리포트]
```

## 디렉토리 구조

```
backup-recovery-system/
├── config/
│   ├── global.conf              # 전역 설정 (SFTP, Slack, 보존정책)
│   └── services/
│       ├── mysql-service.conf   # MySQL 서비스 설정
│       ├── postgresql-service.conf
│       └── mongodb-service.conf
│
├── scripts/
│   ├── backup/
│   │   ├── backup_main.sh       # 백업 오케스트레이터 (진입점)
│   │   ├── backup_db.sh         # DB 백업 (MySQL/PG/Mongo)
│   │   ├── backup_web.sh        # 웹/앱 소스 백업
│   │   └── backup_logs.sh       # 앱 로그 + OS 로그 백업
│   ├── monitor/
│   │   ├── monitor_main.sh      # 모니터링 오케스트레이터 (진입점)
│   │   └── check_backup.sh      # 파일 존재/크기/보안 점검
│   ├── restore/
│   │   ├── restore_main.sh      # 복원 오케스트레이터 (진입점)
│   │   ├── restore_db.sh        # DB 복원
│   │   └── restore_web.sh       # 웹/앱 + 로그 복원
│   └── utils/
│       ├── common.sh            # 로깅, 압축, 체크섬 유틸
│       ├── slack_notify.sh      # Slack 웹훅 알림
│       └── sftp_helper.sh       # SFTP 업로드/다운로드
│
├── cron/
│   └── crontab.example          # 크론탭 예시
│
└── docs/
    ├── architecture.md          # 이 문서
    ├── setup.md                 # 설치 가이드
    └── restore_guide.md         # 복원 절차

```

## 데이터 흐름

### 백업 흐름
```
backup_main.sh
  ├── load global.conf
  ├── for each service/*.conf:
  │   ├── load service config
  │   ├── acquire lock
  │   ├── sftp_test_connection
  │   ├── backup_database()     → mysqldump/pg_dump/mongodump
  │   │   └── compress → sftp_upload_with_checksum
  │   ├── backup_web_modules()  → tar.gz
  │   │   └── compress → sftp_upload_with_checksum
  │   ├── backup_app_logs()     → find + tar.gz
  │   │   └── compress → sftp_upload_with_checksum
  │   ├── backup_os_logs()      → journalctl + cp
  │   │   └── compress → sftp_upload_with_checksum
  │   └── release lock
  └── print_results + slack_send_daily_report
```

### 모니터링 흐름
```
monitor_main.sh
  ├── sftp_test_connection
  ├── for each service:
  │   ├── check_service_backup(date)
  │   │   ├── sftp_list(remote/db)      → 파일 존재/크기 점검
  │   │   ├── sftp_list(remote/web)
  │   │   └── sftp_list(remote/logs)
  │   └── check_backup_security()       → 의심 파일 탐지
  ├── generate_text_report()
  ├── generate_html_report()
  └── slack_send_daily_report()         → 이상 시 즉시 알림
```

### 복원 흐름
```
restore_main.sh
  ├── load service config
  ├── sftp_test_connection
  ├── confirm_restore (대화형)
  ├── restore_database(date)
  │   ├── sftp_download
  │   ├── verify_checksum
  │   ├── decompress_files
  │   └── mysql/pg_restore/mongorestore
  ├── restore_web_modules(date)
  │   ├── sftp_download
  │   ├── verify_checksum
  │   └── decompress_files → 원본 경로
  └── slack_notify_restore
```

## 보안 설계

| 항목 | 구현 |
|------|------|
| SFTP 인증 | SSH 키 기반 (패스워드 비권장) |
| 데이터 암호화 | AES-256-CBC (openssl, 선택) |
| 무결성 검증 | SHA-256 체크섬 |
| 중복 실행 방지 | PID 락 파일 |
| 설정 파일 보호 | 600 권한 권고 |
| SFTP Chroot | /backup 내로 제한 |
| 보안 이상 탐지 | 예상치 못한 파일 확장자 감지 |

## 지원 DB

| DB | 백업 도구 | 복원 도구 |
|----|-----------|-----------|
| MySQL / MariaDB | `mysqldump` | `mysql` |
| PostgreSQL | `pg_dump -Fc` | `pg_restore` |
| MongoDB | `mongodump` | `mongorestore` |
