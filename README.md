# cloudflare-exporter

Bash script that uploads Cloudflare Analytics and Billable Usage API data to InfluxDB on an hourly basis.

## Dependencies

- [awk](https://www.gnu.org/software/gawk/manual/gawk.html)
- [bash](https://www.gnu.org/software/bash/)
- [coreutils (cat)](https://www.gnu.org/software/coreutils/)
- [coreutils (date)](https://www.gnu.org/software/coreutils/)
- [curl](https://curl.se/)
- [gzip](https://www.gnu.org/software/gzip/)
- [influxdb v2+](https://docs.influxdata.com/influxdb/v2.6/)
- [jq](https://stedolan.github.io/jq/)
- [systemd](https://systemd.io/)
- Optional:
  - [make](https://www.gnu.org/software/make/) - for automatic installation support
  - [docker](https://docs.docker.com/)

## Relevant documentation

- [Cloudflare Analytics API](https://developers.cloudflare.com/analytics/graphql-api/)
- [Cloudflare Queues metrics](https://developers.cloudflare.com/queues/observability/metrics/)
- [Cloudflare Billable Usage API](https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/get_account_usage_v2)
- [Cloudflare AI Crawl Control GraphQL API](https://developers.cloudflare.com/ai-crawl-control/reference/graphql-api/)
- [Cloudflare GraphQL Schema](https://pages.johnspurlock.com/graphql-schema-docs/cloudflare.html)
- [InfluxDB API](https://docs.influxdata.com/influxdb/v2.6/write-data/developer-tools/api/)
- [Systemd Timers](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [reddec/compose-scheduler](https://github.com/reddec/compose-scheduler)

## Installation

### With Docker

#### docker-compose

1. Configure `cloudflare_exporter.conf` (see the configuration section below).
1. Run it.

   ```bash
   docker compose up --detach
   ```

#### docker build & run

1. Build the docker image.

   ```bash
   docker build . --tag cloudflare-exporter
   ```

1. Configure `cloudflare_exporter.conf` (see the configuration section below).
1. Run it.

   ```bash
    docker run --rm --init --tty --interactive --read-only --cap-drop ALL --security-opt no-new-privileges:true --cpus 2 -m 64m --pids-limit 16 --volume ./cloudflare_exporter.conf:/app/cloudflare_exporter.conf:ro ghcr.io/rare-magma/cloudflare-exporter:latest
    ```

### With the Makefile

For convenience, you can install this exporter with the following command or follow the manual process described in the next paragraph.

```bash
make install
$EDITOR $HOME/.config/cloudflare_exporter.conf
```

### Manually

1. Copy `cloudflare_exporter.sh` to `$HOME/.local/bin/` and make it executable.

2. Copy `cloudflare_exporter.conf` to `$HOME/.config/`, configure it (see the configuration section below) and make it read only.

3. Copy the systemd unit and timer to `$HOME/.config/systemd/user/`:

   ```bash
   cp cloudflare-exporter.* $HOME/.config/systemd/user/
   ```

4. and run the following command to activate the timer:

   ```bash
   systemctl --user enable --now cloudflare-exporter.timer
   ```

It's possible to trigger the execution by running manually:

```bash
systemctl --user start cloudflare-exporter.service
```

### Config file

The config file has a few options:

```bash
INFLUXDB_HOST='influxdb.example.com'
INFLUXDB_API_TOKEN='ZXhhbXBsZXRva2VuZXhhcXdzZGFzZGptcW9kcXdvZGptcXdvZHF3b2RqbXF3ZHFhc2RhCg=='
ORG='home'
BUCKET='cloudflare'
CLOUDFLARE_API_TOKEN='ZXhhbXBsZXRva2VuZXhhcXdzZGFzZGptcW9kcXdvZGptcXdvZHF3b2RqbXF3ZHFhc2RhCg=='
CLOUDFLARE_ACCOUNT_EMAIL='email@example.com'
CLOUDFLARE_ACCOUNT_TAG='aa0a0aa000a0000aa00a00aa0e000a0a'
```

- `INFLUXDB_HOST` should be the FQDN of the influxdb server.
- `ORG` should be the name of the influxdb organization that contains the cloudflare data bucket defined below.
- `BUCKET` should be the name of the influxdb bucket that will hold the cloudflare data.
- `INFLUXDB_API_TOKEN` should be the influxdb API token value.
  - This token should have write access to the `BUCKET` defined above.
- `CLOUDFLARE_API_TOKEN` should be the cloudflare API token value.
  - This token should be assigned the `All zones - Analytics:Read` and `Zone Read` permissions.
  - Additionally, the `Account Analytics:Read` permission is necessary for workers and Queues metrics.
  - The `Workers KV Storage Read` and `Queues Read` permissions allow automatic discovery of KV namespaces and Queues.
  - The `Billing Read` permission is necessary for billable usage metrics.
- `CLOUDFLARE_ACCOUNT_TAG` should be the tag associated with the cloudflare account.
- Required for cloudflare accounts on a paid plan:
  - `CLOUDFLARE_ACCOUNT_EMAIL` should be the email associated with the paid cloudflare account.

## Troubleshooting

Run the script manually with bash set to trace:

```bash
bash -x $HOME/.local/bin/cloudflare_exporter.sh
```

Check the systemd service logs and timer info with:

```bash
journalctl --user --unit cloudflare-exporter.service
systemctl --user list-timers
```

## Exported metrics

- cloudflare_stats_browser: Page views broken down by browser
- cloudflare_stats_content_type: Request statistics broken down by content type
- cloudflare_stats_countries: Request statistics broken down by country
- cloudflare_stats_ip: Request statistics broken down by robot type
- cloudflare_stats_responses: Request statistics broken down by response status code
- cloudflare_stats: General request statistics
- cloudflare_stats_workers: Workers statistics grouped by hour
- cloudflare_stats_pf: Pages Functions statistics grouped by hour
- cloudflare_stats_kv_ops: KV operation statistics grouped by hour
- cloudflare_stats_kv_storage: KV storage statistics
- cloudflare_stats_queue_backlog: Queue backlog bytes and messages grouped by minute
- cloudflare_stats_queue_delayed_backlog: Delayed queue backlog messages grouped by minute
- cloudflare_stats_queue_consumers: Queue consumer concurrency grouped by minute
- cloudflare_stats_queue_operations: Queue operation counts and bytes grouped by minute
- cloudflare_stats_d1: D1 query volume, row, response-byte, and query-time statistics
- cloudflare_stats_d1_storage: D1 database storage size
- cloudflare_stats_d1_queries: D1 query count, rows read/written, and P50/P95/P99 query latency grouped by five-minute interval
- cloudflare_stats_r2_operations: R2 requests and response bytes grouped by bucket, storage class, and operation outcome
- cloudflare_stats_r2_storage: R2 bucket object and storage statistics grouped by storage class
- cloudflare_stats_email_sending: Email Service sending counts grouped by hour and delivery metadata
- cloudflare_stats_email_routing: Email Service routing counts grouped by hour and routing metadata
- cloudflare_stats_ai_crawl: AI crawler request and response-byte statistics grouped by hour, crawler user agent, and host
- cloudflare_billable_usage: Daily billable usage and costs grouped by service, service family, unit, and zone

## Exported metrics example

```bash
cloudflare_stats_browser,zone="example.com",browserFamily="ChromeMobileWebview" pageViews=2 1703894400
cloudflare_stats_content_type,zone="example.com",edgeResponse="txt" bytes=11089,requests=8 1703894400
cloudflare_stats_countries,zone="example.com",country="CA" bytes=312170,requests=14,threats=0 1703894400
cloudflare_stats_ip,zone="example.com",ipType="searchEngine" requests=21 1703894400
cloudflare_stats_responses,zone="example.com",status=403 requests=1 1703894400
cloudflare_stats,zone="example.com" bytes=2032039,cachedBytes=40607,cachedRequests=17,encryptedBytes=2020727,encryptedRequests=251,pageViews=178,requests=266,threats=0,uniqueVisitors=2 1703894400
cloudflare_stats_workers,account=aa0a0aa000a0000aa00a00aa0e000a0a,worker=worker-name status="scriptThrewException",cpuTimeP50=1246,cpuTimeP99=1246,durationP50=0.001246,durationP99=0.001246,responseBodySizeP50=0,responseBodySizeP99=0,wallTimeP50=1605,wallTimeP99=1605,clientDisconnects=0,cpuTimeUs=1246,duration=0.001246,errors=1,requests=1,responseBodySize=0,subrequests=0,wallTime=1605 1727340566
cloudflare_stats_pf,account=aa0a0aa000a0000aa00a00aa0e000a0a,scriptName=pages-worker--1111111-production status="success",usageModel="standard",cpuTimeP50=3492,cpuTimeP99=3700,durationP50=0.004010875,durationP99=0.016313376,clientDisconnects=0,duration=0.024276250000000003,errors=0,requests=3,responseBodySize=4614,subrequests=0,wallTime=194210 1727431200
cloudflare_stats_kv_ops,account=aa0a0aa000a0000aa00a00aa0e000a0a,namespace=999999aba99dd9999ef99ab78965ab1c actionType="read",result="hot_read",responseStatusCode=200,latencyMsP50=116,latencyMsP99=116,objectBytes=1737,requests=1 1727445600
cloudflare_stats_kv_storage,account=aa0a0aa000a0000aa00a00aa0e000a0a,namespace=999999aba99dd9999ef99ab78965ab1c byteCount=5369,keyCount=1 1727442000
cloudflare_stats_queue_backlog,account=aa0a0aa000a0000aa00a00aa0e000a0a,queue=queue-id bytes=128,messages=2 1782864000
cloudflare_stats_queue_delayed_backlog,account=aa0a0aa000a0000aa00a00aa0e000a0a,queue=queue-id messages=1 1782864000
cloudflare_stats_queue_consumers,account=aa0a0aa000a0000aa00a00aa0e000a0a,queue=queue-id concurrency=1 1782864000
cloudflare_stats_queue_operations,account=aa0a0aa000a0000aa00a00aa0e000a0a,queue=queue-id,actionType=WriteMessage operations=1,billableOperations=1,bytes=64,retryCount=0,lagTime=0 1782864000
cloudflare_stats_ai_crawl,zone=example.com,crawler=GPTBot/1.0,host=example.com requests=4,edgeResponseBytes=512 1782864000
cloudflare_billable_usage,account=aa0a0aa000a0000aa00a00aa0e000a0a,billingCurrency=USD,service=Workers\ Standard,serviceFamily=Workers,consumedUnit=GB-months consumedQuantity=150000,pricingQuantity=150000,contractedCost=0.75,billedCost=0,effectiveCost=0,cumulatedPricingQuantity=0,cumulatedContractedCost=2.25 1738368000
cloudflare_stats_d1,account=999999aba99dd9999ef99ab78965ab1c,database=111111aba11dd1111ef11ab11111ab1c readQueries=100,writeQueries=20,rowsRead=1000,rowsWritten=200,queryBatchResponseBytes=8192,queryBatchTimeMs=1.2,queryBatchTimeMsP90=3.5 1786147200
cloudflare_stats_d1_queries,account=999999aba99dd9999ef99ab78965ab1c,database=111111aba11dd1111ef11ab11111ab1c,region=WNAM,role=primary queries=120,rowsRead=1000,rowsWritten=200,queryDurationMsP50=0.8,queryDurationMsP95=2.1,queryDurationMsP99=3.4 1786186200
cloudflare_stats_d1_storage,account=999999aba99dd9999ef99ab78965ab1c,database=111111aba11dd1111ef11ab11111ab1c databaseSizeBytes=274432 1786147200
cloudflare_stats_r2_operations,account=999999aba99dd9999ef99ab78965ab1c,bucket=bucket-name,storageClass=Standard,actionType=GetObject,actionStatus=success,responseStatusCode=200 requests=4,responseBytes=279670 1786186200
cloudflare_stats_r2_storage,account=999999aba99dd9999ef99ab78965ab1c,bucket=bucket-name,storageClass=Standard objectCount=4,uploadCount=0,payloadSize=279670,metadataSize=130 1786186200
```

## Example grafana dashboard

In `cloudflare-dashboard.json` there is an example of the kind of dashboard that can be built with `cloudflare-exporter` data:

<img src="dashboard-screenshot.png" alt="Grafana dashboard screenshot" title="Example grafana dashboard" width="100%">

Import it by doing the following:

1. Create a dashboard
2. Click the dashboard's settings button on the top right.
3. Go to JSON Model and then paste there the content of the `cloudflare-dashboard.json` file.

## Uninstallation

### With the Makefile

For convenience, you can uninstall this exporter with the following command or follow the process described in the next paragraph.

```bash
make uninstall
```

### Manually

Run the following command to deactivate the timer:

```bash
systemctl --user disable --now cloudflare-exporter.timer
```

Delete the following files:

```bash
~/.local/bin/cloudflare_exporter.sh
~/.config/cloudflare_exporter.conf
~/.config/systemd/user/cloudflare-exporter.timer
~/.config/systemd/user/cloudflare-exporter.service
```

## Credits

- [reddec/compose-scheduler](https://github.com/reddec/compose-scheduler)

This project takes inspiration from the following:

- [rare-magma/pbs-exporter](https://github.com/rare-magma/pbs-exporter)
- [jorgedlcruz/cloudflare-grafana](https://github.com/jorgedlcruz/cloudflare-grafana)
- [mad-ady/prometheus-borg-exporter](https://github.com/mad-ady/prometheus-borg-exporter)
- [OVYA/prometheus-borg-exporter](https://github.com/OVYA/prometheus-borg-exporter)
