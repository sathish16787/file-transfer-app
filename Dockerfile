FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FILE_TRANSFER_BASE_DIR=/app \
    HOST=0.0.0.0 \
    PORT=5000 \
    FLASK_DEBUG=false 

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/file_move.py  src/upload_index.html ./src/

EXPOSE 5000

CMD ["python","src/file_move.py"]
