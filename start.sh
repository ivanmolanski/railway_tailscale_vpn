#!/bin/sh

# Tailscale sidecar for Railway (userspace networking).
#
# This node is a CLIENT that egresses through a remote exit node (the Oracle
# VPS AirVPN gateway), NOT an exit node itself. Set TAILSCALE_EXIT_NODE to the
# exit node's Tailscale IP (e.g. 100.74.193.1) to route all container egress
# through it. The SOCKS5/HTTP proxy is the standard userspace outbound path.
# It is bound to 0.0.0.0:1055 so sibling Railway services (e.g. code-server)
# can reach it over Railway's private network at
# tailscale-vpn.railway.internal:1055 (WireGuard-encrypted, never public).
./tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking --socks5-server=0.0.0.0:1055 --outbound-http-proxy-listen=0.0.0.0:1055 &
# Bring the node up as a CLIENT:
#   - Mention --advertise-exit-node=false EXPLICITLY: Tailscale refuses to
#     change settings unless all non-default flags are stated. The old
#     deployment persisted --advertise-exit-node (AdvertiseRoutes 0.0.0.0/0),
#     so `up` without the flag fails with "requires mentioning all non-default
#     flags". Passing false clears the advertisement cleanly.
#   - --exit-node=<ip>: route ALL egress through the remote exit node (the
#     Oracle VPS AirVPN gateway) when TAILSCALE_EXIT_NODE is set.
#   - No --reset: the volume persists the node's authenticated state, so it
#     rejoins without needing a fresh auth key.
UP_ARGS="--authkey=${TAILSCALE_AUTHKEY} --hostname=${TAILSCALE_HOSTNAME} --advertise-exit-node=false"
if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
	UP_ARGS="${UP_ARGS} --exit-node=${TAILSCALE_EXIT_NODE} --exit-node-allow-lan-access=true"
fi
UP_ARGS="${UP_ARGS} ${TAILSCALE_ADDITIONAL_ARGS}"
until ./tailscale up ${UP_ARGS}
do
    sleep 0.1
done
# Reinforce client mode with `tailscale set` (updates only explicit prefs).
./tailscale set --advertise-exit-node=false
if [ -n "${TAILSCALE_EXIT_NODE:-}" ]; then
	./tailscale set --exit-node=${TAILSCALE_EXIT_NODE} --exit-node-allow-lan-access=true
fi
sleep infinity
