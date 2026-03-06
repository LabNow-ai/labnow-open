# Develop with the `labnow/developer` image

## Step 1: Start the developemnt environment

Start the development container and enter into the container.

```bash
# method 1:
./tool/cicd/run-dev.sh up
./tool/cicd/run-dev.sh enter

# method 2:
docker run -d \
    --name dev-labnow-open \
    --container-name=dev-labnow-open \
    -p 8888:80 -p 3000:3000 \
    -v $(pwd):/root/ \
    quay.io/labnow/data-science-dev \
    tail -f /dev/null

docker exec -it dev-labnow-open bash
```

## Step 2: Update configs and start the supervisord

```bash
mkdir -pv /etc/supervisord && ln -sf /root/src/labnow-open-etc/supervisord.conf   /etc/supervisord/
mkdir -pv /etc/caddy       && ln -sf /root/src/labnow-open-etc/Caddyfile          /etc/caddy/

export STATIC_DIR=/root/src/labnow-open-web/dist && start-supervisord.sh
```

## Step 3: Access the service from the browser

http://localhost:8888/

## Step 4: Build the image and run the built image

```bash
docker build -t quay.io/labnow-dev/labnow-open-dev:latest \
    -f src/labnow-open.Dockerfile \
    --build-arg PROFILE_LOCALIZE=aliyun-pub .

docker run --rm -it \
    --name dev-labnow-open \
    -p 8080:80 \
    quay.io/labnow-dev/labnow-open-dev:latest
```
