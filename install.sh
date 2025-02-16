#!/bin/bash
# Scripts copied from https://github.com/MecSimCalc/firecracker-containerd/blob/main/docs/quickstart.md
# Tested on Ubuntu 20.04 (LTS) x64, x86_64 architecture, AMD CPUs

set -ex # exit on error

# Update the server
sudo DEBIAN_FRONTEND=noninteractive apt-get --yes update
sudo DEBIAN_FRONTEND=noninteractive apt-get --yes upgrade # press enter on any popups
sudo DEBIAN_FRONTEND=noninteractive apt-get --yes dist-upgrade


cd ~
ARCH="$(uname -m)"

# Install git, Go 1.17, make, curl
sudo mkdir -p /etc/apt/sources.list.d
sudo DEBIAN_FRONTEND=noninteractive add-apt-repository --yes ppa:longsleep/golang-backports # required to install golang-1.17
sudo DEBIAN_FRONTEND=noninteractive apt --yes update
sudo DEBIAN_FRONTEND=noninteractive apt-get \
  install --yes \
  golang-1.17 \
  make \
  git \
  curl \
  e2fsprogs \
  util-linux \
  bc \
  gnupg

# Debian's Go 1.17 package installs "go" command under /usr/lib/go-1.17/bin
export PATH=/usr/lib/go-1.17/bin:$PATH
sudo ln -sf /usr/lib/go-1.17/bin/go /usr/bin/

cd ~

# Install Docker CE
# Docker CE includes containerd, but we need a separate containerd binary, built
# in a later step
# https://docs.docker.com/engine/install/ubuntu/
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $(whoami)

# Install device-mapper
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y dmsetup


##############################################################################

cd ~

# Check out firecracker-containerd and build it.  This includes:
# * firecracker-containerd runtime, a containerd v2 runtime
# * firecracker-containerd agent, an inside-VM component
# * runc, to run containers inside the VM
# * a Debian-based root filesystem configured as read-only with a read-write
#   overlay
# * firecracker-containerd, an alternative containerd binary that includes the
#   firecracker VM lifecycle plugin and API
# * tc-redirect-tap and other CNI dependencies that enable VMs to start with
#   access to networks available on the host
cd firecracker-containerd
sg docker -c 'make all image firecracker'
sudo make install install-firecracker demo-network

cd ~

# Download kernel
curl -fsSL -o hello-vmlinux.bin https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin

# Configure our firecracker-containerd binary to use our new snapshotter and
# separate storage from the default containerd binary
sudo mkdir -p /etc/firecracker-containerd
sudo mkdir -p /var/lib/firecracker-containerd/containerd
# Create the shim base directory for which firecracker-containerd will run the
# shim from
sudo mkdir -p /var/lib/firecracker-containerd
sudo tee /etc/firecracker-containerd/config.toml <<EOF
version = 2
disabled_plugins = ["io.containerd.grpc.v1.cri"]
root = "/var/lib/firecracker-containerd/containerd"
state = "/run/firecracker-containerd"
[grpc]
  address = "/run/firecracker-containerd/containerd.sock"
[plugins]
  [plugins."io.containerd.snapshotter.v1.devmapper"]
    pool_name = "fc-dev-thinpool"
    base_image_size = "10GB"
    root_path = "/var/lib/firecracker-containerd/snapshotter/devmapper"

[debug]
  level = "debug"
EOF

# Setup device mapper thin pool
sudo mkdir -p /var/lib/firecracker-containerd/snapshotter/devmapper
cd /var/lib/firecracker-containerd/snapshotter/devmapper
DIR=/var/lib/firecracker-containerd/snapshotter/devmapper
POOL=fc-dev-thinpool

if [[ ! -f "${DIR}/data" ]]; then
    sudo touch "${DIR}/data"
    sudo truncate -s 100G "${DIR}/data"
fi

if [[ ! -f "${DIR}/metadata" ]]; then
    sudo touch "${DIR}/metadata"
    sudo truncate -s 2G "${DIR}/metadata"
fi

DATADEV="$(sudo losetup --output NAME --noheadings --associated ${DIR}/data)"
if [[ -z "${DATADEV}" ]]; then
    DATADEV="$(sudo losetup --find --show ${DIR}/data)"
fi

METADEV="$(sudo losetup --output NAME --noheadings --associated ${DIR}/metadata)"
if [[ -z "${METADEV}" ]]; then
    METADEV="$(sudo losetup --find --show ${DIR}/metadata)"
fi

SECTORSIZE=512
DATASIZE="$(sudo blockdev --getsize64 -q ${DATADEV})"
LENGTH_SECTORS=$(bc <<< "${DATASIZE}/${SECTORSIZE}")
DATA_BLOCK_SIZE=128
LOW_WATER_MARK=32768
THINP_TABLE="0 ${LENGTH_SECTORS} thin-pool ${METADEV} ${DATADEV} ${DATA_BLOCK_SIZE} ${LOW_WATER_MARK} 1 skip_block_zeroing"
echo "${THINP_TABLE}"

if ! $(sudo dmsetup reload "${POOL}" --table "${THINP_TABLE}"); then
    sudo dmsetup create "${POOL}" --table "${THINP_TABLE}"
fi

cd ~

# Configure the aws.firecracker runtime
# The long kernel command-line configures systemd inside the Debian-based image
# and uses a special init process to create a read-write overlay on top of the
# read-only image.
sudo mkdir -p /var/lib/firecracker-containerd/runtime
sudo cp ~/firecracker-containerd/tools/image-builder/rootfs.img /var/lib/firecracker-containerd/runtime/default-rootfs.img
sudo cp ~/hello-vmlinux.bin /var/lib/firecracker-containerd/runtime/default-vmlinux.bin
sudo mkdir -p /etc/containerd
sudo tee /etc/containerd/firecracker-runtime.json <<EOF
{
  "firecracker_binary_path": "/usr/local/bin/firecracker",
  "cpu_template": "T2",
  "log_fifo": "fc-logs.fifo",
  "log_levels": ["debug"],
  "metrics_fifo": "fc-metrics.fifo",
  "kernel_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules ro systemd.unified_cgroup_hierarchy=0 systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init",
  "default_network_interfaces": [{
    "CNIConfig": {
      "NetworkName": "fcnet",
      "InterfaceName": "veth0"
    }
  }]
}
EOF



# Setup systemd to run firecracker-containerd service
sudo tee /etc/systemd/system/firecracker-containerd.service <<EOF
[Unit]
Description=Firecracker Containerd
After=network.target

[Service]
ExecStart=sudo firecracker-containerd --config /etc/firecracker-containerd/config.toml
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable firecracker-containerd.service
sudo systemctl start firecracker-containerd.service



echo "Installation Done."
