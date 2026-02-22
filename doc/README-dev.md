# Develop with the `labnow/developer` image

```bash
docker run -d \
    --name dev-labnow-open \
    -p 20080:80 \
    -v $(pwd):/root/dev \
    quay.io/labnow/developer tail -f /dev/null
```

```bash
docker exec -it dev-labnow-open bash

   mkdir -pv /etc/supervisord && ln -sf /root/dev/src/labnow-oss-etc/supervisord.conf /etc/supervisord/ \
&& mkdir -pv /etc/caddy       && ln -sf /root/dev/src/labnow-oss-etc/Caddyfile        /etc/caddy/

export STATIC_DIR=/root/dev/src/labnow-oss-web/dist

start-supervisord.sh
```

http://localhost:20080/

## Build the image

```bash
docker build -t quay.io/labnow-ai/labnow-oss \
    -f src/labnow-oss.Dockerfile \
    --build-arg PROFILE_LOCALIZE=aliyun-pub .

docker run --rm -it \
    -p 20180:80 \
    quay.io/labnow-ai/labnow-oss
```
