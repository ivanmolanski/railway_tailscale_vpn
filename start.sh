#!/bin/sh

# Tailscale sidecar for Railway (userspace networking).
#
# This node is a CLIENT that egresses through a remote exit node (the Oracle
# VPS AirVPN gateway), NOT an exit node itself. Set TAILSCALE_EXIT_NODE to the
# exit node's Tailscale IP (e.g. 100.74.193.1) to route all container egress
# through it. The SOCKS5 proxy on localhost:1055 is the standard userspace
# outbound path for apps in this container (bound to localhost only).
./tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 &
# Bring the node up (auth + hostname). No --reset: the volume persists the
# node's authenticated state, so it rejoins without needing a fresh key.
until ./tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname=${TAILSCALE_HOSTNAME} ${TAILSCALE_ADDITIONAL_ARGS}
do
    sleep 0.1
done
# Switch the node to CLIENT mode with `tailscale set` (only updates the
# explicitly-set preferences, no re-auth):
#   - --advertise-exit-node=false : stop offering this node as an exit node
#     (clears the persisted AdvertiseRoutes 0.0.0.0/0 from the old config).
#   - --exit-node=<ip>            : route ALL egress through the remote exit
#     node (the Oracle VPS AirVPN gateway) when TAILSCALE_EXIT_NODE is set.
./tailscale set --advertise-exit-node=false
if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
	./tailscale set --exit-node=${TAILSCALE_EXIT_NODE} --exit-node-allow-lan-access=true
fi
sleep infinity
