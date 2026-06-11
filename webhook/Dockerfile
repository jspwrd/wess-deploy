FROM python:3.12-alpine

# bash + docker cli for deploy.sh, curl for notifications.
# No git: deploys pull prebuilt images, never source.
RUN apk add --no-cache bash docker-cli docker-cli-compose curl

WORKDIR /app
COPY server.py .

EXPOSE 9000

CMD ["python", "-u", "server.py"]
