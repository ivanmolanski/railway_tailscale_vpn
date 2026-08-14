#!/bin/sh

# Tailscale sidecar for Railway (userspace networking).
#
# This node is a CLIENT that egresses through a remote exit node (the Oracle
# VPS AirVPN gateway), NOT an exit node itself. Set TAILSCALE_EXIT_NODE to the
# exit node's Tailscale IP (e.g. 100.74.193.1) to route all container egress
# through it. The SOCKS5 proxy on localhost:1055 is the standard userspace
# outbound path for apps in this container (bound to localhost only).
./tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 &
# Build the tailscale up invocation: auth + hostname always; exit node as a
# client when TAILSCALE_EXIT_NODE is set; any additional args appended.
UP_ARGS="--authkey=${TAILSCALE_AUTHKEY} --hostname=${TAILSCALE_HOSTNAME}"
if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
	UP_ARGS="${UP_ARGS} --exit-node=${TAILSCALE_EXIT_NODE} --exit-node-allow-lan-access=true"
fi
UP_ARGS="${UP_ARGS} ${TAILSCALE_ADDITIONAL_ARGS}"
until ./tailscale up ${UP_ARGS}
do
    sleep 0.1
done
sleep infinity
