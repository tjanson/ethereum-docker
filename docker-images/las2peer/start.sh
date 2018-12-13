#!/bin/bash
set -e

ETH_PROPS_DIR=/app/las2peer/etc/
ETH_PROPS=i5.las2peer.registry.data.RegistryConfiguration.properties

function waitForEndpoint {
    /app/wait-for-command/wait-for-command.sh -c "nc -z ${1} ${2:-80}" --time ${3:-10} --quiet
}

function host { echo ${1%%:*}; }
function port { echo ${1#*:}; }

if [ -n "$LAS2PEER_CONFIG_ENDPOINT" ]; then
    echo Attempting to autoconfigure registry blockchain parameters ...
    if waitForEndpoint $(host ${LAS2PEER_CONFIG_ENDPOINT}) $(port ${LAS2PEER_CONFIG_ENDPOINT}) 600; then
        echo Downloading ...
        wget "http://${LAS2PEER_CONFIG_ENDPOINT}/${ETH_PROPS}" -O "${ETH_PROPS_DIR}${ETH_PROPS}"
        echo done.
    else
        echo Registry configuration endpoint specified but not accessible. Aborting.
        exit 1
    fi
fi

if [ -n "$LAS2PEER_ETH_HOST" ]; then
    echo Replacing Ethereum client host in config files ...
    sed -i "s|^endpoint.*$|endpoint = http://${LAS2PEER_ETH_HOST}:8545|" "${ETH_PROPS_DIR}${ETH_PROPS}"
    sed -i "s/eth-bootstrap/${LAS2PEER_ETH_HOST}/" /app/las2peer-registry-contracts/truffle.js
    echo done.
fi

if [ -n "$LAS2PEER_BOOTSTRAP" ]; then
    echo Skipping migration, contracts should already be deployed
else
    echo Waiting for Ethereum client ...
    if waitForEndpoint ${LAS2PEER_ETH_HOST} 8545 300; then
        echo Starting truffle migration ...
        cd /app/las2peer-registry-contracts
        ./node_modules/.bin/truffle migrate --network docker_boot 2>&1 | tee migration.log
        echo done. Setting contract addresses in config file ...
        cat migration.log | grep '^  \w*: 0x\w*$' | sed -e 's/:/Address =/;s/^  \(.\)/\L\1/' | tail -n 3 >> "${ETH_PROPS_DIR}${ETH_PROPS}"
        echo done. Serving config files at :8001 ...
        cd /app/las2peer/
        pm2 start --silent http-server -- ./etc -p 8001
    else
        echo Ethereum client not accessible. Aborting.
        exit 2
    fi
fi

cd /app/las2peer
if [ -n "$LAS2PEER_BOOTSTRAP" ]; then
    if waitForEndpoint $(host ${LAS2PEER_BOOTSTRAP}) $(port ${LAS2PEER_BOOTSTRAP}) 600; then
        echo Las2peer bootstrap available, continuing.
    else
        echo Las2peer bootstrap specified but not accessible. Aborting.
        exit 3
    fi
fi

# it's realistic for different nodes to use different wallets (i.e., to have
# different node operators). this function echos the N-th wallet if the
# hostname is "something-something-N". if not, first wallet is used
function selectWallet {
    PEER_NUM=$(hostname | cut -d'-' -f3) # get N out of las2peer-peer-N
    wallets=(/app/keystore/*)
    if [[ $PEER_NUM =~ ^[0-9]+$ && $PEER_NUM -lt ${#wallets[@]} ]]; then
        echo "${wallets[$PEER_NUM]}"
    else
        echo "${wallets[0]}"
    fi
}

echo Starting las2peer node ...
java -cp "core/src/main/resources/:core/export/jars/*:restmapper/export/jars/*:webconnector/export/jars/*:core/lib/*:restmapper/lib/*:webconnector/lib/*" i5.las2peer.tools.L2pNodeLauncher --port $LAS2PEER_PORT $([ -n "$LAS2PEER_BOOTSTRAP" ] && echo "--bootstrap $LAS2PEER_BOOTSTRAP") --node-id-seed $RANDOM --ethereum-wallet "$(selectWallet)"  startWebConnector "node=getNodeAsEthereumNode()" "registry=node.getRegistryClient()" "n=getNodeAsEthereumNode()" "r=n.getRegistryClient()" interactive
