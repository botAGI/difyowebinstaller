FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY dify_pipeline.py .

RUN adduser --disabled-password --no-create-home appuser
USER appuser

EXPOSE 9099

CMD ["uvicorn", "dify_pipeline:app", "--host", "0.0.0.0", "--port", "9099"]
