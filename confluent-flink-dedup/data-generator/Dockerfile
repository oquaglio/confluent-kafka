FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.8.4 /uv /bin/uv
WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt
COPY data_generator.py .
ENV PYTHONUNBUFFERED=1
CMD ["python", "data_generator.py"]
