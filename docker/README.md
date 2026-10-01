## Paperclip Docker Setup

```sh
# Build docker image
docker build -t abichinger/paperclip:latest .

# Push docker image
docker save abichinger/paperclip:latest | pv | gzip | ssh user@YOUR_VPS_IP 'gunzip | docker load'
```

## Verifying the image contents

- [`verify-nono-toolchain.md`](./verify-nono-toolchain.md) — assert that a built
  image really contains the Flutter + Android client toolchain, at the versions
  the `mobile-toolchain` stage of the root `Dockerfile` pins. Start here.
- [`verify-nono-toolchain.selftest.sh`](./verify-nono-toolchain.selftest.sh) —
  proves that the harness above detects faults, without needing Docker or a built
  image. Safe to run on a developer machine and in CI.
