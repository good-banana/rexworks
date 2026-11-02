---
title: Search indexing rollout
status: in review
owner: platform-team
updated: 2026-11-01
tags:
  - search
  - infrastructure
---

# Search indexing rollout

This document describes how we move search indexing from the nightly batch job to the streaming pipeline. The new indexer runs as `index-worker` and reads change events from the `documents.changes` topic. See the [streaming pipeline guide](https://example.com/docs/streaming) for background, or jump to [Rollout steps](#rollout-steps) if you already know the system.

## Goals

- Index new documents within one minute of being saved
- Retire the nightly `reindex_all` cron job
- Keep search results identical during the migration

## Current state

The batch job rebuilds the full index every night at 02:00 UTC. A document saved at 02:05 does not appear in search until the next run, almost a full day later.

### Measurements

| Metric | Batch job | Streaming (staging) |
| --- | --- | --- |
| Time to searchable | up to 24 h | 38 s (p95) |
| CPU per day | 11.2 core-hours | 3.4 core-hours |
| Failed documents | 0.4% | 0.1% |

## Rollout steps

1. Deploy `index-worker` with `WRITE_MODE=shadow` so it writes to a separate index.
2. Compare shadow results against production for one week.
3. Switch reads to the streaming index behind the `search.streaming` flag.
4. Remove the cron job once the flag is at 100%.

### Schedule by region

| Region | Shadow start | Comparison ends | Internal users | 10% | 50% | 100% | Batch index removed | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| us-east-1 | 2026-11-03 | 2026-11-10 | 2026-11-11 | 2026-11-12 | 2026-11-14 | 2026-11-17 | 2026-11-24 | platform-team |
| eu-west-1 | 2026-11-10 | 2026-11-17 | 2026-11-18 | 2026-11-19 | 2026-11-21 | 2026-11-24 | 2026-12-01 | platform-team |
| ap-south-1 | 2026-11-17 | 2026-11-24 | 2026-11-25 | 2026-11-26 | 2026-11-28 | 2026-12-01 | 2026-12-08 | search-oncall |

- [x] Shadow index deployed in staging
- [ ] Comparison dashboard reviewed
- [ ] Flag enabled for internal users

> [!WARNING]
> Do not delete the batch index until the flag has been at 100% for seven days. It is the only rollback path.

### Configuration

```yaml
index-worker:
  topic: documents.changes
  batch_size: 200
  write_mode: shadow
```

Restart the worker after changing its configuration:

```sh
kubectl --namespace search rollout restart deployment/index-worker && kubectl --namespace search rollout status deployment/index-worker --timeout=10m
```

```mermaid
flowchart LR
  Editor --> Changes[documents.changes]
  Changes --> Worker[index-worker]
  Worker --> Index[(Search index)]
```

## Open risks

Large imports can produce bursts of more than 50,000 events per minute.[^burst] The worker backs off automatically, but freshness drops during the burst.

[^burst]: Measured during the October customer import.
