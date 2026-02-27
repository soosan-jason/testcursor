# 복원 절차 가이드

## 복원 유형별 절차

### 1. 전체 서비스 복원 (장애 복구)

```bash
# 1단계: 이용 가능한 백업 날짜 확인
./scripts/restore/restore_main.sh --service mysql-service --list

# 2단계: 전체 복원 (확인 프롬프트 있음)
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115

# 3단계: 확인 없이 즉시 복원 (자동화 스크립트용)
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --force
```

### 2. DB만 복원

```bash
# 전체 DB 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --component db

# 특정 DB만 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --component db \
  --db myapp_db
```

### 3. 웹 모듈만 복원

```bash
# 원본 경로로 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --component web

# 별도 경로로 복원 (검증 후 이동 권장)
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --component web \
  --target-dir /tmp/restore_check
```

### 4. 로그만 복원 (분석/감사용)

```bash
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date 20240115 \
  --component logs \
  --target-dir /tmp/log_analysis
```

---

## 장애 시나리오별 대응

### 시나리오 A: DB 데이터 손상/삭제

```bash
# 1. 서비스 중단 (데이터 추가 손상 방지)
sudo systemctl stop myapp

# 2. 최신 백업 날짜 확인
./scripts/restore/restore_main.sh --service mysql-service --list

# 3. DB 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date <최신날짜> \
  --component db \
  --force

# 4. 복원 검증
mysql -u root -e "SHOW TABLES;" myapp_db

# 5. 서비스 재시작
sudo systemctl start myapp
```

### 시나리오 B: 웹 파일 손상 (랜섬웨어 등)

```bash
# 1. 서비스 격리
sudo systemctl stop nginx myapp

# 2. 손상된 파일 백업
mv /var/www/myapp /var/www/myapp.compromised

# 3. 웹 파일 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date <감염전_날짜> \
  --component web \
  --force

# 4. 권한 복구
chown -R www-data:www-data /var/www/myapp
chmod -R 755 /var/www/myapp

# 5. 서비스 재시작
sudo systemctl start nginx myapp

# 6. 보안 사고 로그 분석
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date <감염전_날짜> \
  --component logs \
  --target-dir /tmp/security_analysis
```

### 시나리오 C: 신규 서버 이전

```bash
# 1. 새 서버에 클라이언트 패키지 설치 (setup.md 참고)

# 2. 설정 파일에서 RESTORE_TARGET_HOST 변경
vi config/services/mysql-service.conf
# RESTORE_TARGET_HOST=new-server.example.com

# 3. 전체 복원
./scripts/restore/restore_main.sh \
  --service mysql-service \
  --date <최신날짜> \
  --force
```

---

## 복원 검증 체크리스트

복원 완료 후 반드시 아래 항목을 확인하세요:

- [ ] DB 테이블 수 및 레코드 수 확인
- [ ] DB 접속 정상 여부
- [ ] 웹 파일 경로 및 권한 확인
- [ ] 애플리케이션 설정 파일 확인 (`config/`, `.env`)
- [ ] 서비스 정상 기동 확인
- [ ] 헬스체크 엔드포인트 응답 확인
- [ ] 로그에 에러 없음 확인

---

## 체크섬 수동 검증

```bash
# 백업 파일 무결성 수동 확인
sha256sum -c backup_file.tar.gz.sha256
```
