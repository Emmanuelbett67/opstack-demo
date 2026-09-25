FROM python:3.12-slim
WORKDIR /app
COPY simulator.py .
USER nobody
EXPOSE 9100
ENTRYPOINT ["python", "-u", "simulator.py"]
