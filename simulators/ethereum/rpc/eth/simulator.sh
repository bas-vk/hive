#!/usr/bin/env bash

# Create and start a valid bootnode for the clients to find each other
BOOTNODE_KEYHEX=5ce1f6fc42c817c38939498ee7fcdd9a06fa9d947d02d42dfe814406f370c4eb
BOOTNODE_ENODEID=6433e8fb82c4638a8a6d499d40eb7d8158883219600bfd49acb968e3a37ccced04c964fa87b3a78a2da1b71dc1b90275f4d055720bb67fad4a118a56925125dc

BOOTNODE_IP=`ifconfig eth0 | grep 'inet addr' | cut -d: -f2 | awk '{print $1}'`
BOOTNODE_ENODE="enode://$BOOTNODE_ENODEID@$BOOTNODE_IP:30303"

echo "Start bootnode..."
/bootnode --nodekeyhex $BOOTNODE_KEYHEX --addr=0.0.0.0:30303 &

N_NODES=8         # Number of nodes to start
N_MINERS=2        # Number of nodes that have the miner running and act as light servers
N_LIGHT_SERVER=2  # Number of nodes that can serve light client requests
N_LIGHT_CLIENTS=2 # Number of nodes that run in light mode

# netPeerCount executes an RPC request to a node to retrieve its current number
# of connected peers.
#
# If looks up the IP address of the node from the hive simulator and executes the
# actual peer lookup. As the result is hex encoded, it will decode and return it.
function netPeerCount {
	local peers=`curl -sf -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":0}' $1:8545 | jq '.result' | tr -d '"'`
	echo $((16#${peers#*x}))
}

# waitPeers verifies whether a node has a given number of peers, and if not waits
# a bit and retries a few times (to avoid devp2p pending handshakes and similar
# anomalies). If the peer count doesn't converge to the desired target, the method
# will fail.
function waitPeers {
	local ip=`curl -sf $HIVE_SIMULATOR/nodes/$1`

	for i in `seq 1 20`; do
		# Fetch the current peer count and stop if it's correct
		peers=`netPeerCount $ip`
		if [ "$peers" -ge "$2" ]; then
		    echo "Node $1 ($ip) has $peers/$2 peers"
		    break
		fi
		# Seems peer count is wrong, unless too many trials, sleep a bit and retry
		if [ "$i" == "20" ]; then
			echo "Invalid peer count for $1 ($ip): have $peers, want $2"
			exit -1
		fi

		sleep 0.5
	done
}

# waitBlock waits until the block number of a remote node is at least the specified
# one, periodically polling and sleeping otherwise. There is no timeout, the method
# will block until it succeeds.
function waitBlock {
	local ip=`curl -sf $HIVE_SIMULATOR/nodes/$1`

	while [ true ]; do
		block=`ethBlockNumber $ip`
		if [ "$block" -gt "$2" ]; then
			break
		fi
		sleep 0.5
	done
}

# instruct HIVE to start N_NODES nodes, by default the RPC node will start the RPC
# interface with all API modules enabled. $N_MINERS nodes will have the miner running.
nodes=()
lightServers=() # see workaround lower in file
lightClients=() # see workaround lower in file

for i in `seq 1 $N_NODES`; do
	if [ "$i" -le "$N_MINERS" ]; then
	    node=(`curl -sf -X POST --data "HIVE_CHAIN_ID=7" --data "HIVE_FORK_HOMESTEAD=0" --data "HIVE_FORK_SPURIOUS=0" --data "HIVE_INIT_KEYS=/keystores$i" --data-urlencode "HIVE_BOOTNODE=$BOOTNODE_ENODE" --data "HIVE_MINER=0x0000000000000000000000000000000000000001" $HIVE_SIMULATOR/nodes`)
	    echo "Started geth node $i/$node as miner"
        nodes+=($node)
	elif [ "$i" -le $((N_MINERS+N_LIGHT_SERVER)) ]; then
        node=(`curl -sf -X POST --data "HIVE_CHAIN_ID=7" --data "HIVE_FORK_HOMESTEAD=0" --data "HIVE_FORK_SPURIOUS=0" --data "HIVE_INIT_KEYS=/keystores$i" --data-urlencode "HIVE_BOOTNODE=$BOOTNODE_ENODE" --data "HIVE_LIGHT_SERVER=1" $HIVE_SIMULATOR/nodes`)
        echo "Started geth node $i/$node as light client server"
        nodes+=($node)
        lightServers+=($node)
	elif [ "$i" -le $((N_MINERS+N_LIGHT_SERVER+N_LIGHT_CLIENTS)) ]; then
        node=(`curl -sf -X POST --data "HIVE_CHAIN_ID=7" --data "HIVE_FORK_HOMESTEAD=0" --data "HIVE_FORK_SPURIOUS=0" --data "HIVE_INIT_KEYS=/keystores$i" --data-urlencode "HIVE_BOOTNODE=$BOOTNODE_ENODE" --data "HIVE_NODETYPE=light" $HIVE_SIMULATOR/nodes`)
        echo "Started geth node $i/$node as light client"
        nodes+=($node)
        lightClients+=($node)
	else
	    node=(`curl -sf -X POST --data "HIVE_CHAIN_ID=7" --data "HIVE_FORK_HOMESTEAD=0" --data "HIVE_FORK_SPURIOUS=0" --data "HIVE_INIT_KEYS=/keystores$i" --data-urlencode "HIVE_BOOTNODE=$BOOTNODE_ENODE" $HIVE_SIMULATOR/nodes`)
	    echo "Started geth node $i/$node"
	    nodes+=($node)
	fi
done

sleep 5 # Wait a bit until nodes are registered with the bootnode

# add light server peers to light clients manually, workaround until discovery v5 is stable.
for c in "${lightClients[@]}"
do
	for s in "${lightServers[@]}"
    do
        # retrieve light server enode and do an addPeer on the client
        clientIp=(`curl -sf $HIVE_SIMULATOR/nodes/$c`)
        serverIp=(`curl -sf $HIVE_SIMULATOR/nodes/$s`)

        sEnode=`curl -sf --data '{"id": 1, "method": "admin_nodeInfo", "jsonrpc": "2.0"}' $serverIp:8545 | jq '.result.enode'`
        replace="\[::\]"
        sEnode=${sEnode/$replace/$serverIp}

        header="Content-Type: application/json"
request_body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "method": "admin_addPeer",
  "id": 1,
  "params": [$sEnode]
}
EOF
)
        curl -i -X POST -H "$header" -d "$request_body" $clientIp:8545 #--trace-ascii /dev/stdout
    done
done

# Wait a bit for the nodes to all find each other
for id in ${nodes[@]}; do
	waitPeers $id $((N_NODES/3))
done

# Collect IP addresses of nodes for RPC endpoints
ips=()
for id in ${nodes[@]}; do
    ips+=(`curl -sf $HIVE_SIMULATOR/nodes/$id`)
done

# Execute RPC test suite
echo "Run RPC tests against ${ips[@]}..."
/rpc.test -test.v -test.run Eth $"${ips[@]}"

#echo "Run RPC-WEBSOCKET tests..."
#/rpc.test -test.run Eth/websocket $"${ips[@]}"

# Run hive (must be run from root directory of hive repo)
# hive --client=go-ethereum:master --test=NONE --sim=ethereum/rpc/eth --docker-noshell -loglevel 6
#
# Logs can be found in workspace/logs/simulations/ethereum/rpc\:eth\[go-ethereum\:develop\]/simulator.log
