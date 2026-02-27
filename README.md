# Ubuntu SFTP 백업 & 복원 시스템

Ubuntu 기반 서비스들의 DB, 웹 모듈, 앱 로그, OS 로그를 SFTP 백업 서버로 수집하고 모니터링 및 복원을 지원하는 범용 백업 시스템입니다.

## 주요 기능

| 기능 | 설명 |
|------|------|
| **범용 백업** | MySQL/MariaDB, PostgreSQL, MongoDB 지원 |
| **설정 기반** | `.conf` 파일만으로 서비스별 독립 설정 |
| **자동 모니터링** | 백업 누락/크기이상/보안이상 탐지 |
| **Slack 알림** | 실패/경고 즉시 알림 + 일별 리포트 |
| **무결성 검증** | SHA-256 체크섬 자동 생성/검증 |
| **암호화 지원** | AES-256-CBC 선택적 암호화 |
| **안전한 복원** | 확인 프롬프트 + 체크섬 검증 후 복원 |

## 빠른 시작

```bash
# 1. 전역 설정 수정
vi config/global.conf        # SFTP 서버, Slack 웹훅 설정

# 2. 서비스별 설정 파일 작성
cp config/services/mysql-service.conf config/services/myservice.conf
vi config/services/myservice.conf

# 3. 실행 권한 부여
chmod +x scripts/**/*.sh

# 4. 백업 실행 (드라이런)
./scripts/backup/backup_main.sh --dry-run --all

# 5. 실제 백업
./scripts/backup/backup_main.sh --all

# 6. 모니터링
./scripts/monitor/monitor_main.sh

# 7. 복원
./scripts/restore/restore_main.sh --service myservice --date 20240115
```

## 디렉토리 구조

```
├── config/
│   ├── global.conf              # 전역 설정
│   └── services/                # 서비스별 설정
├── scripts/
│   ├── backup/                  # 백업 스크립트
│   ├── monitor/                 # 모니터링 스크립트
│   ├── restore/                 # 복원 스크립트
│   └── utils/                   # 공통 유틸리티
├── cron/
│   └── crontab.example          # 크론탭 예시
└── docs/
    ├── setup.md                 # 설치 가이드
    ├── architecture.md          # 아키텍처 문서
    └── restore_guide.md         # 복원 절차 가이드
```

## 크론탭 스케줄 (권장)

| 시간 | 작업 |
|------|------|
| 매일 02:00 | 전체 서비스 백업 |
| 매일 06:00 | 백업 현황 모니터링 + Slack 리포트 |
| 매주 일요일 05:00 | 오래된 로그/리포트 정리 |

자세한 내용은 [설치 가이드](docs/setup.md)와 [복원 절차 가이드](docs/restore_guide.md)를 참고하세요.