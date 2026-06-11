FROM python:3.12-alpine

RUN apk add --no-cache bash git docker-cli docker-cli-compose curl

WORKDIR /app
COPY server.py .

EXPOSE 9000

CMD ["python", "-u", "server.py"]
