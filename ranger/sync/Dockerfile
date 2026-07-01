FROM python:3.11-alpine
RUN pip install --no-cache-dir requests
COPY sync.py /sync.py
COPY fallback-rules.json /fallback-rules.json
CMD ["python3", "/sync.py"]
