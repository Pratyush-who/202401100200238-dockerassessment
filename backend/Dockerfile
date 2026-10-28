FROM python:3.13-slim

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user
RUN useradd --system --no-create-home --uid 10001 appuser
USER appuser

EXPOSE 5000
CMD ["python", "app.py"]