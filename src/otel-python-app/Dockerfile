FROM python:3.11-slim

WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Create non-root user
RUN groupadd -g 1001 appgroup && \
    useradd -u 1001 -g appgroup -s /bin/false appuser && \
    chown -R appuser:appgroup /app

USER appuser

# Expose port
EXPOSE 8080

# Run the application
CMD ["python", "app.py"]
