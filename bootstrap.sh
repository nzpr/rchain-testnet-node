#!/bin/bash

# Install system
set -e -o pipefail

while :; do
	_hostname="$(hostname -f)"
	if [[ $_hostname == *.* && $_hostname != *.internal ]]; then
		break
	fi
	systemctl restart systemd-networkd
	echo "Waiting for FQDN..."
	sleep 10
done

apt install -y --no-install-recommends \
    apt-transport-https gnupg2 \
    collectd collectd-utils liboping0 jq dnsutils \
	bpfcc-tools iotop \
	openjdk-11-jdk-headless \
	nginx libnginx-mod-http-fancyindex \
	coreutils tree \
	build-essential autoconf automake libtool \
	python3 python3-venv python3-dev \
	unzip graphviz subversion

curl -sSfL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
echo 'deb [arch=amd64] https://download.docker.com/linux/ubuntu cosmic stable' \
    >/etc/apt/sources.list.d/docker-ce.list

curl -sSfL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb http://packages.cloud.google.com/apt gcsfuse-bionic main" \
	>/etc/apt/sources.list.d/gcsfuse.list

apt update
apt install -y --no-install-recommends --no-upgrade docker-ce
apt install -y --no-install-recommends gcsfuse

pushd scripts >/dev/null
python3 -mvenv venv
source ./venv/bin/activate
# pyjq setup fails with errors similar to https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=917006
# explicitly installing wheel fixes the error
pip3 install wheel
# upgrade setuptools for pyrchain to work
pip3 install -U setuptools>=40.1
pip3 install -U -r requirements.txt
popd >/dev/null

network_dir="node-files${PROFILE:+.$PROFILE}"
node_dir=$network_dir/$(hostname)

install -C -m644 collectd.conf -t /etc/collectd/
systemctl restart collectd

mkdir -m710 -p /var/lib/rnode-static
chgrp www-data /var/lib/rnode-static

mkdir -m750 -p /var/lib/rnode-diag
chgrp www-data /var/lib/rnode-diag

install -C -m600 \
	$node_dir/node.key.pem \
	-t /var/lib/rnode-static/

install -C -m644 \
	logback.xml \
	$node_dir/node.certificate.pem \
	-t /var/lib/rnode-static/

rm -f /var/lib/rnode-static/validator-public-keys.txt

for net_node_dir in $network_dir/node*; do
	net_node_pubkey=$(
		./scripts/merge-hocon-fragments -i $net_node_dir/rnode.conf.d |\
		jq -r .rnode.casper.'"validator-public-key"')
	echo $net_node_pubkey >>/var/lib/rnode-static/validator-public-keys.txt
done

mkdir -m700 -p /var/lib/rnode-static/rnode.conf.d

shopt -s nullglob

install -C -m600 \
	rnode.conf.d/*.conf \
	$network_dir/rnode.conf.d/*.conf \
	$node_dir/rnode.conf.d/*.conf \
	-t /var/lib/rnode-static/rnode.conf.d/

# User override rnode.conf. Broken link will just be ignored.
ln -sf /var/lib/rnode/rnode.override.conf \
	/var/lib/rnode-static/rnode.conf.d/999-rnode.override.conf

shopt -u nullglob

if [[ -z "$(docker ps -q -f name='^logspout$')" ]]; then
	docker rm logspout || true
	docker pull gliderlabs/logspout
	docker run -d --restart=unless-stopped --name=logspout \
		-p 8181:80 -v /var/run/docker.sock:/var/run/docker.sock \
		gliderlabs/logspout
fi

install -C sshd_config -t /etc/ssh/
systemctl reload sshd

install -C -m644 nginx/* -t /etc/nginx/
systemctl reload nginx

# Start node
set -e -o pipefail
source "$(dirname $0)/functions"

echo "Pulling Docker image $RNODE_DOCKER_IMAGE"
docker pull $RNODE_DOCKER_IMAGE

mkdir -p /var/lib/rnode /var/lib/rnode/genesis

ln -sf /var/lib/rnode-static/node.*.pem /var/lib/rnode/

######################################################################
# create bonds.txt file

cp /root/bonds.txt /var/lib/rnode/genesis/bonds.txt
cp /root/wallets.txt /var/lib/rnode/genesis/wallets.txt

######################################################################
# generate config file

merge_rnode_conf_fragments

# Create rnode.redacted.conf with default permissions so that it's
# accessible by nginx. umask should have world readable bit cleared.
jq 'del(.rnode.server.casper."validator-private-key")' \
	< /var/lib/rnode/rnode.conf \
	> /var/lib/rnode/rnode.redacted.conf

######################################################################
# load config file and adjust command line options

parse_rnode_config

if [[
	$rnode_server_standalone != true &&
	-n $rnode_server_bootstrap
]]; then
	eval "$(parse-node-url "$rnode_server_bootstrap" bootstrap_)"
fi

if [[
	$rnode_server_standalone == true ||
	-z $rnode_server_bootstrap ||
	$bootstrap_node_id == $(get_tls_node_id)
]]; then
	rnode_server_standalone=true
	echo "Node is standalone"
else
	bootstrap_ip="$(dig +short $bootstrap_hostname A | tail -1)"
	if [[ -n "$bootstrap_ip" ]]; then
		echo "Node will bootstrap from $bootstrap_hostname ($bootstrap_ip)"
	else
		echo "Failed to resolve bootstrap hostname '$bootstrap_hostname'" >&2
		exit 1
	fi
fi

if [[
	$rnode_casper_required_signatures -gt 0 &&
	$rnode_server_standalone != true
]]; then
	rnode_casper_genesis_validator=true
fi

######################################################################
# initial network isolation

if ! iptables -L rnode_iblock >/dev/null 2>&1; then
	iptables -N rnode_iblock
fi
if ! iptables -L rnode_oblock >/dev/null 2>&1; then
	iptables -N rnode_oblock
fi
if ! iptables -L rnode_isel >/dev/null 2>&1; then
	iptables -N rnode_isel
	iptables -I INPUT 1 -j rnode_isel
fi
if ! iptables -L rnode_osel >/dev/null 2>&1; then
	iptables -N rnode_osel
	iptables -I OUTPUT 1 -j rnode_osel
fi

iptables -F rnode_iblock
iptables -A rnode_iblock -i lo -j RETURN
if [[ $rnode_server_standalone != true ]]; then
	iptables -A rnode_iblock -p tcp --dport "$rnode_server_port" -s "$bootstrap_ip" -j RETURN
	iptables -A rnode_iblock -p tcp --dport "$rnode_server_port" -j REJECT
elif [[ $rnode_casper_required_signatures -eq 0 ]]; then
	iptables -A rnode_iblock -p tcp --dport "$rnode_server_port" -j REJECT
else
	# Let bootstrap's server port open to any validator when genesis block
	# creation requires non-zero number of signatures. Unauthorized validators
	# are not in bonds.txt so it shouldn't be a problem.
	true
fi
iptables -A rnode_iblock -p tcp --dport "$rnode_server_port_kademlia" -j REJECT
iptables -A rnode_iblock -p tcp --dport "$rnode_grpc_port_external" -j REJECT

iptables -F rnode_oblock
iptables -A rnode_oblock -o lo -j RETURN
iptables -A rnode_oblock -p tcp --dport "$bootstrap_port_kademlia" -j REJECT

iptables -F rnode_isel
iptables -A rnode_isel -j rnode_iblock
iptables -F rnode_osel
iptables -A rnode_osel -j rnode_oblock

######################################################################
# BEGIN docker run

docker_args=(
	--name=rnode
	--network=host
	-v /var/lib/rnode:/var/lib/rnode
	-v $DIAG_DIR:$DIAG_DIR
	-v /var/lib/rnode-static:/var/lib/rnode-static:ro
)

launcher_args=(
	-J-Xss5m
	-XX:+HeapDumpOnOutOfMemoryError
	-XX:HeapDumpPath=$DIAG_DIR/heapdump_OOM.hprof
	-XX:+ExitOnOutOfMemoryError
	-XX:ErrorFile=$DIAG_DIR/hs_err.log
	-XX:MaxJavaStackTraceDepth=100000
	-Dlogback.configurationFile=/var/lib/rnode-static/logback.xml
	-c /var/lib/rnode/rnode.conf
	$(get_rnode_launcher_args)
)

run_args=(
	--network "$network_id"
	$(get_rnode_run_args)
)

if [[ -f /var/lib/rnode-static/environment.docker ]]; then
	docker_args+=(--env-file=/var/lib/rnode-static/environment.docker)
fi

if [[ -f /var/lib/rnode-static/local.env ]]; then
	source /var/lib/rnode-static/local.env
fi

logcmd docker run -d \
	${docker_args[@]}  \
	nuttzipper/rnode:bm \
	${launcher_args[@]} \
	run ${run_args[@]}
	>/dev/null

# END docker run
######################################################################

i=2
sleep_time=5
echo "Waiting $((i*sleep_time))s for RNode to start"

while (( i )); do
	container_id="$(docker ps -q -f name=rnode)"
	if [[ -n "$container_id" ]]; then
		echo "RNode is running"
		nohup docker logs -f $container_id &> $DIAG_DIR/console.log &

		node_pid="$(docker inspect -f '{{.State.Pid}}' rnode || echo 0)"
		if (( node_pid )); then
			nohup $INSTALL_DIR/pmap.py "$node_pid" "perf-bootstrap.c.developer-222401.internal" 8091 "$network_id" >/dev/null 2>&1 &
		fi
		break
	fi

	sleep $sleep_time
	: $((i--))
done

wait_time_left=600
sleep_time=10
echo "Waiting ${wait_time_left}s for approved block"

while (( wait_time_left > 0 )); do
	if [[ -z "$(docker ps -q -f ID=$container_id)" ]]; then
		echo "RNode is not running" >&2
		if [[ -n "$(docker ps -aq -f ID=$container_id)" ]]; then
			echo "----- BEGIN RNODE OUTPUT -----" >&2
			docker logs $container_id >&2 || true
			echo "----- END RNODE OUTPUT -----" >&2
		fi
		exit 1
	fi

	height="$(docker exec $container_id ./bin/rnode show-blocks |\
		sed -n '/^count: /{s///;p;q}')" || true
	if (( height )); then
		echo "Found approved block"
		break
	fi

	sleep $sleep_time
	: $(( wait_time_left -= sleep_time ))
done

if (( wait_time_left <= 0 )); then
	echo "Did not find approved block" >&2
	exit 1
fi

iptables -F rnode_isel
iptables -F rnode_osel

echo Finished
