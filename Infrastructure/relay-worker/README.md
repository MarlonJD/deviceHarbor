# DeviceHarbor hosted relay

This Worker is the public rendezvous node for DeviceHarbor’s CGNAT-safe
transport. The Mac and iPhone both open outbound WebSocket connections to the
Worker; the Durable Object for the room forwards the framed DeviceHarbor
messages between the two peers. No inbound connection to the Mac or iPhone is
required.

The Mac companion provisions a fresh temporary Worker at runtime with
`wrangler deploy --temporary`, generates a random room and access token, and
sends the resulting offer to the iPhone over the local pairing channel. The
peers then connect to `/v1/rooms/<room-id>` on that temporary Worker. The room
is isolated by a Durable Object and both peers use outbound WSS, so CGNAT does
not require an inbound port. No Worker URL or Cloudflare credential is included
in either app build.

This temporary deployment flow is a development bootstrap. Before production,
replace the local Wrangler provisioner with a DeviceHarbor-owned control plane
that creates short-lived relay instances without exposing Cloudflare
credentials to clients.

## Deploy

Install dependencies, generate binding types, validate, and deploy with
Wrangler from this directory:

```sh
npm install
npx wrangler types
npm run check
npx wrangler deploy
```

The deployed endpoint is:

```text
wss://<worker-host>/v1/rooms/<room-id>
```

The Worker supports `GET /health` for a non-authenticated liveness check.
