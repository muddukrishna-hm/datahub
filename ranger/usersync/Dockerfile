FROM python:3.11-alpine
RUN pip install --no-cache-dir requests ldap3
COPY sync-users.py /sync-users.py
CMD ["python3", "/sync-users.py"]
