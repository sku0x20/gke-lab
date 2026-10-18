# Dev access to databases

How devs reach in-cluster databases (Studio 3T, mongosh, DBeaver) without `kubectl` and without a public database endpoint. Research only, nothing deployed.

## Requirements

- No Kubernetes access for devs.
- Per user, per database: dev-a may reach mongo, not valkey.
- Mongo replica set mode, not a direct connection to one member. The driver discovers members by their cluster names (`mongo-rs0-N.mongo-rs0.mongo.svc.cluster.local`), so the client must resolve those through the tunnel. This rules out most simple options.

## Two layers

- Network: who can reach which host:port. That's the access tool.
- Database: what they can do (Mongo users and roles, `spec.users`) and what they did (Percona audit log, see `mongo/NOTES.md`). Kept separate, so the access tool needs no database awareness.

## Ruled out

| Option | Why not |
|---|---|
| Public LoadBalancer | the database on the internet, guarded by a password only |
| `kubectl port-forward` | needs Kubernetes access; one pod per forward, so only `directConnection` to the primary |
| SOCKS proxy pod + port-forward | still Kubernetes access; doesn't work for our tools |
| API gateway (Kong etc.) | identity is HTTP-level; raw TCP (the Mongo protocol) can only be filtered by IP or client cert |
| Teleport | most complete (database-aware, audit), but Community Edition restricts commercial use since v16; database audit comes from Percona anyway |
| Boundary (+ Vault) | BSL; one host per target. Vault's short-lived database users are the part worth revisiting |
| Warpgate | no MongoDB support |
| Pomerium | HTTP-first; TCP is one route per host, so one per replset member |
| GCP IAP TCP forwarding | IAM per destination group (IP range or FQDN in the VPC), free, GCP-native. But one tunnel = one host:port, and cluster names need GKE DNS extended to the VPC. Awkward for a replset |

## Candidates

| Tool | Hosted | In cluster | Replset DNS | Notes |
|---|---|---|---|---|
| Twingate | SaaS | connector pod | resources by DNS name with wildcards, resolved by the connector: should just work | small free tier (reported ~5 users) |
| Cloudflare Zero Trust | SaaS | `cloudflared` pod, outbound only | WARP routes IP ranges; `cluster.local` needs DNS setup (Local Domain Fallback to kube-dns?) | largest free tier (reported ~50 users), traffic goes through Cloudflare |
| Tailscale / NetBird / Headscale | SaaS or self-hosted | subnet router or operator | split DNS for `cluster.local` | WireGuard mesh with ACLs |
| Firezone | SaaS or self-hosted | gateway | DNS resources resolved on the gateway | check licence and plans |
| OpenZiti | self-hosted (or NetFoundry hosted) | tunneler/router | intercepts by hostname | Apache 2.0, but heavy: controller with its own PKI, a public edge router, identity enrollment, a policy model |

Free-tier numbers come from comparison blogs that disagree; check the vendor's pricing page.

## Decision

- Now: a hosted tool, Twingate or Cloudflare. One connector pod in the cluster, rules in their dashboard.
- Later: OpenZiti as a learning stage of its own (self-hosted control plane, same idea as `SELF-MANAGED.md`).

## Next

Proof of concept for both hosted tools: Studio 3T in replica set mode through the tunnel, failover followed. Start with Twingate (DNS-name resources). Needs an account and a network or team created in their dashboard first.
