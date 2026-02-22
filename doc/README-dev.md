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
export STATIC_DIR=/root/dev/src/labnow-oss-web/dist && start-supervisord.sh
```

http://localhost:20080/

## Build the image

```bash
docker build -t quay.io/labnow-dev/labnow-oss-dev:latest \
    -f src/labnow-oss.Dockerfile \
    --build-arg PROFILE_LOCALIZE=aliyun-pub .

docker run --rm -it \
    --name dev-labnow-open \
    -p 20080:80 \
    quay.io/labnow-dev/labnow-oss-dev:latest
```
