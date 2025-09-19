# Lightweight base
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install runtime deps (ok if file is empty / comments only)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app
COPY sample_app ./sample_app

# Run the CLI module by default; any args passed to `docker run` will be appended
ENTRYPOINT ["python", "-m", "sample_app"]
