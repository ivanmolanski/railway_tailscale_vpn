#!/bin/sh

# Tailscale sidecar for Railway (userspace networking).
#
# This node is a CLIENT that egresses through a remote exit node (the Oracle
# VPS AirVPN gateway), NOT an exit node itself. Set TAILSCALE_EXIT_NODE to the
# exit node's Tailscale IP (e.g. 100.74.193.1) to route all container egress
# through it. The SOCKS5 proxy on localhost:1055 is the standard userspace
# outbound path for apps in this container (bound to localhost only).
./tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 &
# Build the tailscale up invocation:
#   - --reset: apply the exact preferences below, clearing any persisted
#     advertisement from a previous deployment (e.g. the old
#     --advertise-exit-node with AdvertiseRoutes 0.0.0.0/0).
#   - --advertise-exit-node= (empty): explicitly stop advertising this node as
#     an exit node. This node is a client, not an exit node.
#   - --exit-node=<ip>: route all egress through the remote exit node when
#     TAILSCALE_EXIT_NODE is set.
UP_ARGS="--authkey=${TAILSCALE_AUTHKEY} --hostname=${TAILSCALE_HOSTNAME} --reset --advertise-exit-node="
if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
	UP_ARGS="${UP_ARGS} --exit-node=${TAILSCALE_EXIT_NODE} --exit-node-allow-lan-access=true"
fi
UP_ARGS="${UP_ARGS} ${TAILSCALE_ADDITIONAL_ARGS}"
until ./tailscale up ${UP_ARGS}
do
    sleep 0.1
done
sleep infinity
