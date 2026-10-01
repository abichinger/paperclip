## Paperclip Docker Setup

```sh
# Build docker image
docker build -t abichinger/paperclip:latest .

# Push docker image
docker save abichinger/paperclip:latest | pv | gzip | ssh user@YOUR_VPS_IP 'gunzip | docker load'
```