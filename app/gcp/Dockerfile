FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY web/ ./web/

# Cloud Run inyecta $PORT (por defecto 8080)
ENV PORT=8080
ENV WEB_DIR=web
CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:$PORT --workers 2 --threads 4 main:app"]
