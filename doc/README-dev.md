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

   mkdir -pv /etc/supervisord && ln -sf /root/dev/src/labnow-base/control/supervisord.conf /etc/supervisord/ \
&& mkdir -pv /etc/caddy       && ln -sf /root/dev/src/labnow-base/control/Caddyfile        /etc/caddy/

export STATIC_DIR=/root/dev/src/labnow-base/webgui
export STATIC_DIR=/root/dev/src/labnow-base/labnow-open/dist

start-supervisord.sh
```

http://localhost:20080/home/
