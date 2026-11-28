FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:0.13.10 /uv /bin/uv
WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt
COPY sf_emulator.py .
ENV PYTHONUNBUFFERED=1
CMD ["python", "sf_emulator.py"]
