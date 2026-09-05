FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    debootstrap \
    qemu-user-static \
    binfmt-support \
    fdisk \
    dosfstools \
    e2fsprogs \
    gdisk \
    parted \
    rsync \
    binutils \
    unzip \
    wget \
    curl \
    patch \
    gnupg \
    ca-certificates \
    python3-minimal \
    make \
    gzip \
    zstd \
    kmod \
    udev \
    && rm -rf /var/lib/apt/lists/*
