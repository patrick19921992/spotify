FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DATA_DIR=/data \
    MEDIA_DIR=/media \
    PORT=8080 \
    PUID=99 \
    PGID=100 \
    UMASK=002 \
    TZ=Europe/Berlin \
    HOME=/tmp

WORKDIR /srv
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY alembic.ini entrypoint.sh ./
COPY app ./app
RUN chmod 755 entrypoint.sh

VOLUME ["/data", "/media"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8080') + '/api/health', timeout=4)" || exit 1

ENTRYPOINT ["/srv/entrypoint.sh"]
