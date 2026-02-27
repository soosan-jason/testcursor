# 설치 및 설정 가이드

## 1. 사전 요구사항

### 백업 대상 서버 (각 서비스 서버)
```bash
# 필수 패키지
sudo apt-get install -y openssh-client curl openssl python3

# DB별 클라이언트
sudo apt-get install -y mysql-client          # MySQL/MariaDB
sudo apt-get install -y postgresql-client     # PostgreSQL
sudo apt-get install -y mongo-tools           # MongoDB
```

### 백업 서버 (SFTP 서버)
```bash
# OpenSSH SFTP 서버
sudo apt-get install -y openssh-server

# SFTP 전용 계정 생성
sudo useradd -m -d /backup -s /usr/sbin/nologin backupuser
sudo mkdir -p /backup
sudo chown backupuser:backupuser /backup

# SSH 키 기반 인증 설정 (/etc/ssh/sshd_config)
# Match User backupuser
#   ChrootDirectory /backup
#   ForceCommand internal-sftp
#   PasswordAuthentication no
```

## 2. 설치

```bash
# 프로젝트 클론
git clone <repo_url> /opt/backup-recovery-system
cd /opt/backup-recovery-system

# 실행 권한 부여
chmod +x scripts/backup/*.sh
chmod +x scripts/monitor/*.sh
chmod +x scripts/restore/*.sh
chmod +x scripts/utils/*.sh

# 로그 디렉토리 생성
sudo mkdir -p /var/log/backup-system/reports
sudo chown -R backupuser:backupuser /var/log/backup-system
```

## 3. 설정

### 3-1. 전역 설정 (`config/global.conf`)
```bash
# SFTP 서버 정보 수정
SFTP_HOST=your-backup-server.example.com
SFTP_USER=backupuser
SFTP_KEY_FILE=/home/backupuser/.ssh/backup_rsa

# Slack 웹훅 설정
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
SLACK_DEFAULT_CHANNEL=#backup-alerts
```

### 3-2. SSH 키 생성 및 배포
```bash
# 백업 계정에서 키 생성
ssh-keygen -t rsa -b 4096 -f ~/.ssh/backup_rsa -N ""

# 백업 서버에 공개키 등록
ssh-copy-id -i ~/.ssh/backup_rsa.pub -p 22 backupuser@backup-server
```

### 3-3. 서비스별 설정 파일 생성
```bash
# 예시 설정을 복사하여 수정
cp config/services/mysql-service.conf config/services/mydb.conf
vi config/services/mydb.conf
```

필수 항목:
| 항목 | 설명 |
|------|------|
| `SERVICE_NAME` | 서비스 식별자 (영문+하이픈) |
| `DB_TYPE` | mysql \| postgresql \| mongodb |
| `DB_HOST`, `DB_PORT` | DB 접속 정보 |
| `DB_USER`, `DB_PASS` | DB 인증 정보 |
| `WEB_SOURCE_DIRS` | 웹 소스 경로 (콜론 구분) |

### 3-4. 크론탭 등록
```bash
# crontab.example을 참고하여 등록
sudo crontab -u backupuser -e

# 또는 직접 적용
sudo cp cron/crontab.example /etc/cron.d/backup-system
sudo chmod 644 /etc/cron.d/backup-system
```

## 4. 동작 확인

```bash
# 드라이런으로 설정 확인
./scripts/backup/backup_main.sh --dry-run --all

# 특정 서비스 백업 테스트
./scripts/backup/backup_main.sh config/services/mysql-service.conf

# 백업 현황 점검
./scripts/monitor/monitor_main.sh --date $(date -d yesterday '+%Y%m%d')

# 이용 가능한 백업 목록 조회
./scripts/restore/restore_main.sh --service mysql-service --list
```

## 5. 보안 권고사항

1. **설정 파일 권한**: DB 패스워드가 포함된 설정 파일은 600으로 보호
   ```bash
   chmod 600 config/services/*.conf
   chmod 600 config/global.conf
   ```

2. **SSH 키 보호**
   ```bash
   chmod 600 ~/.ssh/backup_rsa
   ```

3. **암호화 백업** (민감한 데이터): `global.conf`에서
   ```
   ENCRYPT_BACKUP=true
   ENCRYPT_PASSPHRASE=YourStrongPassphrase
   ```

4. **SFTP Chroot**: 백업 서버에서 backupuser를 `/backup` 내로 제한

5. **MySQL 패스워드**: `.my.cnf` 파일 사용 권장
   ```ini
   [mysqldump]
   user=backupuser
   password=SecurePassword
   ```
