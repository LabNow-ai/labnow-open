# Develop with the `labnow/developer` image

```bash
docker run -d \
    --name dev-labnow-open \
    --container-name=dev-labnow-open \
    -p 20080:80 \
    -v $(pwd):/root/ \
    quay.io/labnow/data-science-dev tail -f /dev/null

docker exec -it dev-labnow-open bash
```

```bash
mkdir -pv /etc/supervisord && ln -sf /root/src/labnow-open-etc/supervisord.conf   /etc/supervisord/
mkdir -pv /etc/caddy       && ln -sf /root/src/labnow-open-etc/Caddyfile          /etc/caddy/

export STATIC_DIR=/root/src/labnow-open-web/dist && start-supervisord.sh
```

http://localhost:20080/

## Build the image

```bash
docker build -t quay.io/labnow-dev/labnow-open-dev:latest \
    -f src/labnow-open.Dockerfile \
    --build-arg PROFILE_LOCALIZE=aliyun-pub .

docker run --rm -it \
    --name dev-labnow-open \
    -p 20080:80 \
    quay.io/labnow-dev/labnow-open-dev:latest
```
