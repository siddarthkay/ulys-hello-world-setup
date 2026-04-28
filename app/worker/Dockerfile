FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8081
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:8081", "--timeout", "30", "app:app"]
