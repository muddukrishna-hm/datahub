FROM python:3.11-alpine
RUN pip install --no-cache-dir requests
COPY init-policies.py /init-policies.py
CMD ["python3", "/init-policies.py"]
