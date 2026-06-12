FROM python:3.12-alpine

# bash + docker cli for deploy.sh, curl for notifications, util-linux
# flock for deploy serialization (busybox flock lacks -w).
# No git: deploys pull prebuilt images, never source.
RUN apk add --no-cache bash docker-cli docker-cli-compose curl flock

WORKDIR /app
COPY server.py .

EXPOSE 9000

CMD ["python", "-u", "server.py"]
