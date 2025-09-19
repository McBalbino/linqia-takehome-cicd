FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt || true

COPY sample_app /app/sample_app

# Default: run the module. 
ENTRYPOINT ["python"]
CMD ["-m", "sample_app"]
