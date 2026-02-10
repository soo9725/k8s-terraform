# 1. 파이썬 3.9 버전을 기반으로 시작
FROM python:3.9-slim

# 2. 작업 폴더 설정
WORKDIR /app

# 3. 현재 폴더의 모든 파일(webapp.yml, index.html 등)을 컨테이너의 /app으로 복사
COPY . /app

# 4. (옵션) 만약 index.html이 없다면 간단한 파일 생성
RUN echo "Hello from Jenkins Build!" > index.html

# 5. 8000번 포트로 웹 서버 실행
CMD ["python3", "-m", "http.server", "8000"]