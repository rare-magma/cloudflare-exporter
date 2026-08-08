#!/usr/bin/env bash

set -Eeo pipefail

dependencies=(awk cat curl date gzip jq)
for program in "${dependencies[@]}"; do
  command -v "$program" >/dev/null 2>&1 || {
    echo >&2 "Couldn't find dependency: $program. Aborting."
    exit 1
  }
done

AWK=$(command -v awk)
CAT=$(command -v cat)
CURL=$(command -v curl)
DATE=$(command -v date)
GZIP=$(command -v gzip)
JQ=$(command -v jq)

if [[ "${RUNNING_IN_DOCKER}" ]]; then
  source "/app/cloudflare_exporter.conf"
elif [[ -f $CREDENTIALS_DIRECTORY/creds ]]; then
  #shellcheck source=/dev/null
  source "$CREDENTIALS_DIRECTORY/creds"
else
  source "./cloudflare_exporter.conf"
fi

[[ -z "${INFLUXDB_HOST}" ]] && echo >&2 "INFLUXDB_HOST is empty. Aborting" && exit 1
[[ -z "${INFLUXDB_API_TOKEN}" ]] && echo >&2 "INFLUXDB_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${ORG}" ]] && echo >&2 "ORG is empty. Aborting" && exit 1
[[ -z "${BUCKET}" ]] && echo >&2 "BUCKET is empty. Aborting" && exit 1
[[ -z "${CLOUDFLARE_API_TOKEN}" ]] && echo >&2 "CLOUDFLARE_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${CLOUDFLARE_ACCOUNT_TAG}" ]] && echo >&2 "CLOUDFLARE_ACCOUNT_TAG is empty. Aborting" && exit 1
[[ -n "${CLOUDFLARE_ACCOUNT_EMAIL}" ]] && CF_EMAIL_HEADER="X-Auth-Email: ${CLOUDFLARE_ACCOUNT_EMAIL}"

RFC_CURRENT_DATE=$($DATE --rfc-3339=date)
ISO_CURRENT_DATE_TIME=$($DATE --iso-8601=seconds)
ISO_CURRENT_DATE_TIME_1H_AGO=$($DATE --iso-8601=seconds --date "1 hour ago")
ISO_CURRENT_DATE_TIME_2H_AGO=$($DATE --iso-8601=seconds --date "2 hour ago")
D1_DATETIME_START="${RFC_CURRENT_DATE}T00:00:00Z"
INFLUXDB_URL="https://$INFLUXDB_HOST/api/v2/write?precision=s&org=$ORG&bucket=$BUCKET"
CF_URL="https://api.cloudflare.com/client/v4/graphql"
CF_BILLABLE_USAGE_URL="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_TAG/billable-usage"
CF_REST_API_URL="https://api.cloudflare.com/client/v4"
CF_ACCOUNT_API_URL="$CF_REST_API_URL/accounts/$CLOUDFLARE_ACCOUNT_TAG"

cloudflare_list_ids() {
  local endpoint=$1 id_field=$2 page=1 response total_pages

  while :; do
    response=$(
      $CURL --silent --fail --show-error --compressed \
        --header "$CF_EMAIL_HEADER" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$endpoint?page=$page&per_page=1000"
    )

    if [[ $(echo "$response" | $JQ --raw-output '.success') != "true" ]]; then
      echo "$response" | $JQ --raw-output '.errors[]? | .message' >&2
      return 1
    fi

    echo "$response" | $JQ --raw-output --arg id_field "$id_field" '.result[]? | .[$id_field] | select(. != null)'
    total_pages=$(echo "$response" | $JQ '.result_info.total_pages // 1')
    [[ $page -ge $total_pages ]] && break
    ((page++))
  done
}

cloudflare_list_zones() {
  local page=1 response total_pages zones='[]'

  while :; do
    response=$(
      $CURL --silent --fail --show-error --compressed \
        --header "$CF_EMAIL_HEADER" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "$CF_REST_API_URL/zones?account.id=$CLOUDFLARE_ACCOUNT_TAG&page=$page&per_page=50"
    )

    if [[ $(echo "$response" | $JQ --raw-output '.success') != "true" ]]; then
      echo "$response" | $JQ --raw-output '.errors[]? | .message' >&2
      return 1
    fi

    zones=$(echo "$response" | $JQ --compact-output --argjson zones "$zones" '$zones + [.result[]? | {id, domain: .name}]')
    total_pages=$(echo "$response" | $JQ '.result_info.total_pages // 1')
    [[ $page -ge $total_pages ]] && break
    ((page++))
  done

  echo "$zones"
}

CLOUDFLARE_ZONE_LIST=$(cloudflare_list_zones)
[[ $(echo "$CLOUDFLARE_ZONE_LIST" | $JQ 'length') -eq 0 ]] && echo >&2 "No Cloudflare zones found. Aborting" && exit 1
CLOUDFLARE_KV_NAMESPACES=$(cloudflare_list_ids "$CF_ACCOUNT_API_URL/storage/kv/namespaces" id)
CLOUDFLARE_QUEUES=$(cloudflare_list_ids "$CF_ACCOUNT_API_URL/queues" queue_id)

if [[ -n "${CLOUDFLARE_QUEUES}" ]]; then
  for queue_id in $(echo "$CLOUDFLARE_QUEUES"); do
    QUEUES_GRAPHQL_QUERY=$(
      $JQ --null-input --compact-output \
        --arg query "$(
          $CAT <<END_HEREDOC
query GetQueuesAnalytics(\$accountTag: string, \$queueId: string, \$datetimeStart: Time, \$datetimeEnd: Time) {
  viewer {
    accounts(filter: {accountTag: \$accountTag}) {
      queueBacklogAdaptiveGroups(limit: 10000, filter: {queueId: \$queueId, datetime_geq: \$datetimeStart, datetime_leq: \$datetimeEnd}) {
        avg { bytes messages }
        dimensions { datetimeMinute queueId }
      }
      queueDelayedBacklogAdaptiveGroups(limit: 10000, filter: {queueId: \$queueId, datetime_geq: \$datetimeStart, datetime_leq: \$datetimeEnd}) {
        avg { messages }
        dimensions { datetimeMinute queueId }
      }
      queueConsumerMetricsAdaptiveGroups(limit: 10000, filter: {queueId: \$queueId, datetime_geq: \$datetimeStart, datetime_leq: \$datetimeEnd}) {
        avg { concurrency }
        dimensions { datetimeMinute queueId }
      }
      queueMessageOperationsAdaptiveGroups(limit: 10000, filter: {queueId: \$queueId, datetime_geq: \$datetimeStart, datetime_leq: \$datetimeEnd}) {
        count
        sum { bytes billableOperations }
        avg { retryCount lagTime }
        dimensions { datetimeMinute queueId actionType consumerType outcome }
      }
    }
  }
}
END_HEREDOC
        )" \
        --arg accountTag "$CLOUDFLARE_ACCOUNT_TAG" \
        --arg queueId "$queue_id" \
        --arg datetimeStart "$ISO_CURRENT_DATE_TIME_2H_AGO" \
        --arg datetimeEnd "$ISO_CURRENT_DATE_TIME" \
        '{query: $query, variables: {accountTag: $accountTag, queueId: $queueId, datetimeStart: $datetimeStart, datetimeEnd: $datetimeEnd}}'
    )

    cf_queues_json=$(
      $CURL --silent --fail --show-error --compressed --request POST \
        --header "Content-Type: application/json" \
        --header "$CF_EMAIL_HEADER" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        --data "$QUEUES_GRAPHQL_QUERY" "$CF_URL"
    )

    cf_queues_nb_errors=$(echo "$cf_queues_json" | $JQ '.errors | length')
    if [[ $cf_queues_nb_errors -gt 0 ]]; then
      cf_queues_errors=$(echo "$cf_queues_json" | $JQ --raw-output '.errors[] | .message')
      printf "Cloudflare Queues API request failed with: \n%s\nAborting\n" "$cf_queues_errors" >&2
      exit 1
    fi

    cf_stats_queues=$(echo "$cf_queues_json" | $JQ --raw-output --arg account "$CLOUDFLARE_ACCOUNT_TAG" '
    def esc: gsub("\\\\"; "\\\\") | gsub(","; "\\,") | gsub(" "; "\\ ") | gsub("="; "\\=");
    def tag($n; $v): $n + "=" + ($v | tostring | esc);
    def opt($n; $v): if $v == null or $v == "" then "" else tag($n; $v) end;
    .data.viewer.accounts[0] as $data |
    ($data.queueBacklogAdaptiveGroups[]? | . as $row |
        [tag("account"; $account), tag("queue"; $row.dimensions.queueId)] | join(",") as $tags |
        "cloudflare_stats_queue_backlog,\($tags) bytes=\($row.avg.bytes // 0),messages=\($row.avg.messages // 0) \($row.dimensions.datetimeMinute | fromdateiso8601)"),
    ($data.queueDelayedBacklogAdaptiveGroups[]? | . as $row |
        [tag("account"; $account), tag("queue"; $row.dimensions.queueId)] | join(",") as $tags |
        "cloudflare_stats_queue_delayed_backlog,\($tags) messages=\($row.avg.messages // 0) \($row.dimensions.datetimeMinute | fromdateiso8601)"),
    ($data.queueConsumerMetricsAdaptiveGroups[]? | . as $row |
        [tag("account"; $account), tag("queue"; $row.dimensions.queueId)] | join(",") as $tags |
        "cloudflare_stats_queue_consumers,\($tags) concurrency=\($row.avg.concurrency // 0) \($row.dimensions.datetimeMinute | fromdateiso8601)"),
    ($data.queueMessageOperationsAdaptiveGroups[]? | . as $row |
        [tag("account"; $account), tag("queue"; $row.dimensions.queueId), opt("actionType"; $row.dimensions.actionType), opt("consumerType"; $row.dimensions.consumerType), opt("outcome"; $row.dimensions.outcome)] | map(select(. != "")) | join(",") as $tags |
        "cloudflare_stats_queue_operations,\($tags) operations=\($row.count // 0),billableOperations=\($row.sum.billableOperations // 0),bytes=\($row.sum.bytes // 0),retryCount=\($row.avg.retryCount // 0),lagTime=\($row.avg.lagTime // 0) \($row.dimensions.datetimeMinute | fromdateiso8601)")
')

    if [[ -n "$cf_stats_queues" ]]; then
      echo "$cf_stats_queues" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" --header "Accept: application/json" --data-binary @-
    fi
  done
fi

nb_zones=$(echo "$CLOUDFLARE_ZONE_LIST" | $JQ 'length - 1')

for i in $(seq 0 "$nb_zones"); do

  mapfile -t cf_zone < <(echo "$CLOUDFLARE_ZONE_LIST" | $JQ --raw-output ".[${i}] | .id, .domain")
  cf_zone_id=${cf_zone[0]}
  cf_zone_domain="${cf_zone[1]}"

  GRAPHQL_QUERY=$(
    $CAT <<END_HEREDOC
{ "query":
  "query {
    viewer {
      zones(filter: {zoneTag: \$zoneTag}) {
        httpRequests1hGroups(limit:7, filter: \$filter,)   {
          dimensions {
            datetime
          }
          sum {
            browserMap {
              pageViews
              uaBrowserFamily
            }
            bytes
            cachedBytes
            cachedRequests
            contentTypeMap {
              bytes
              requests
              edgeResponseContentTypeName
            }
            countryMap {
              bytes
              requests
              threats
              clientCountryName
            }
            encryptedBytes
            encryptedRequests
            ipClassMap {
              requests
              ipType
            }
            pageViews
            requests
            responseStatusMap {
              requests
              edgeResponseStatus
            }
            threats
            threatPathingMap {
              requests
              threatPathingName
            }
          }
          uniq {
            uniques
          }
        }
      }
    }
  }",
  "variables": {
    "zoneTag": "$cf_zone_id",
    "filter": {
      "date_geq": "$RFC_CURRENT_DATE",
      "date_leq": "$RFC_CURRENT_DATE"
    }
  }
}
END_HEREDOC
  )

  cf_json=$(
    $CURL --silent --fail --show-error --compressed \
      --request POST \
      --header "Content-Type: application/json" \
      --header "$CF_EMAIL_HEADER" \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      --data "$(echo -n $GRAPHQL_QUERY)" \
      "$CF_URL"
  )

  cf_nb_errors=$(echo $cf_json | $JQ ".errors | length")

  if [[ $cf_nb_errors -gt 0 ]]; then
    cf_errors=$(echo $cf_json | $JQ --raw-output ".errors[] | .message")
    printf "Cloudflare API request failed with: \n%s\nAborting\n" "$cf_errors" >&2
    exit 1
  fi

  cf_nb_groups=$(echo $cf_json | $JQ ".data.viewer.zones[0].httpRequests1hGroups | length - 1")

  if [[ $cf_nb_groups -gt 0 ]]; then

    for i in $(seq 0 "$cf_nb_groups"); do
      cf_json_parsed=$(echo $cf_json | $JQ ".data.viewer.zones[0].httpRequests1hGroups[$i]")
      date_value=$(echo $cf_json_parsed | $JQ --raw-output '.dimensions.datetime')
      uniques=$(echo $cf_json_parsed | $JQ '.uniq.uniques // 0')
      ts=$($DATE "+%s" --date="$date_value")

      mapfile -t cf_root_values < <(
        echo $cf_json_parsed | $JQ \
          '.sum | .bytes // 0, .cachedBytes // 0, .cachedRequests // 0, .encryptedBytes, .encryptedRequests // 0, .pageViews // 0, .requests // 0, .threats // 0'
      )

      nb_browsers=$(echo $cf_json_parsed | $JQ '.sum.browserMap | length - 1')
      nb_content_types=$(echo $cf_json_parsed | $JQ '.sum.contentTypeMap | length - 1')
      nb_countries=$(echo $cf_json_parsed | $JQ '.sum.countryMap | length - 1')
      nb_ip_classes=$(echo $cf_json_parsed | $JQ '.sum.ipClassMap | length - 1')
      nb_response_status=$(echo $cf_json_parsed | $JQ '.sum.responseStatusMap | length - 1')
      nb_threat_pathing=$(echo $cf_json_parsed | $JQ '.sum.threatPathingMap | length - 1')

      if [[ $nb_browsers -gt 0 ]]; then
        for j in $(seq 0 "$nb_browsers"); do
          mapfile -t cf_browser_values < <(
            echo $cf_json_parsed | $JQ --raw-output ".sum.browserMap[$j] | .uaBrowserFamily, .pageViews // 0"
          )
          cf_stats+=$(
            printf "\ncloudflare_stats_browser,zone=%s,browserFamily=%s pageViews=%s %s" \
              "$cf_zone_domain" "${cf_browser_values[0]}" "${cf_browser_values[1]}" "$ts"
          )
        done
      fi

      if [[ $nb_content_types -gt 0 ]]; then
        for k in $(seq 0 "$nb_content_types"); do
          mapfile -t cf_ct_values < <(
            echo $cf_json_parsed | $JQ --raw-output ".sum.contentTypeMap[$k] | .bytes // 0, .edgeResponseContentTypeName, .requests // 0"
          )
          cf_stats+=$(
            printf "\ncloudflare_stats_content_type,zone=%s,edgeResponse=%s bytes=%s,requests=%s %s" \
              "$cf_zone_domain" "${cf_ct_values[1]}" "${cf_ct_values[0]}" "${cf_ct_values[2]}" "$ts"
          )
        done
      fi

      if [[ $nb_countries -gt 0 ]]; then
        for l in $(seq 0 "$nb_countries"); do
          mapfile -t cf_country_values < <(
            echo $cf_json_parsed | $JQ --raw-output ".sum.countryMap[$l] | .clientCountryName, .bytes // 0, .requests // 0, .threats // 0"
          )
          cf_stats+=$(
            printf \
              "\ncloudflare_stats_countries,zone=%s,country=%s bytes=%s,requests=%s,threats=%s %s" \
              "$cf_zone_domain" "${cf_country_values[0]}" "${cf_country_values[1]}" \
              "${cf_country_values[2]}" "${cf_country_values[3]}" \
              "$ts"
          )
        done
      fi

      if [[ $nb_ip_classes -gt 0 ]]; then
        for m in $(seq 0 "$nb_ip_classes"); do
          mapfile -t cf_ip_values --raw-output < <(echo $cf_json_parsed | $JQ ".sum.ipClassMap[$m] | .ipType, .requests // 0")
          cf_stats+=$(
            printf \
              "\ncloudflare_stats_ip,zone=%s,ipType=%s requests=%s %s" \
              "$cf_zone_domain" "${cf_ip_values[0]}" "${cf_ip_values[1]}" "$ts"
          )
        done
      fi

      if [[ $nb_response_status -gt 0 ]]; then
        for n in $(seq 0 "$nb_response_status"); do
          mapfile -t cf_response_values < <(
            echo $cf_json_parsed | $JQ ".sum.responseStatusMap[$n] | .edgeResponseStatus, .requests // 0"
          )
          cf_stats+=$(
            printf \
              "\ncloudflare_stats_responses,zone=%s,status=%s requests=%s %s" \
              "$cf_zone_domain" "${cf_response_values[0]}" "${cf_response_values[1]}" "$ts"
          )
        done
      fi

      if [[ $nb_threat_pathing -gt 0 ]]; then
        for o in $(seq 0 "$nb_response_status"); do
          mapfile -t cf_threat_values < <(
            echo $cf_json_parsed | $JQ --raw-output ".sum.threatPathingMap[$o] | .threatPathingMap, .requests // 0"
          )
          cf_stats+=$(
            printf \
              "\ncloudflare_stats_threats,zone=%s,threat=%s requests=%s %s" \
              "$cf_zone_domain" "${cf_threat_values[0]}" "${cf_threat_values[1]}" "$ts"
          )
        done
      fi

      cf_stats+=$(
        printf \
          "\ncloudflare_stats,zone=%s bytes=%s,cachedBytes=%s,cachedRequests=%s,encryptedBytes=%s,encryptedRequests=%s,pageViews=%s,requests=%s,threats=%s,uniqueVisitors=%s %s" \
          "$cf_zone_domain" \
          "${cf_root_values[0]}" "${cf_root_values[1]}" "${cf_root_values[2]}" "${cf_root_values[3]}" \
          "${cf_root_values[4]}" "${cf_root_values[5]}" "${cf_root_values[6]}" "${cf_root_values[7]}" \
          "$uniques" \
          "$ts"
      )
    done

    echo "$cf_stats" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --header "Accept: application/json" \
        --data-binary @-
  fi

  AI_CRAWL_GRAPHQL_QUERY=$(
    $JQ --null-input --compact-output \
      --arg query "$(
        $CAT <<END_HEREDOC
query GetAICrawlAnalytics(\$zoneTag: string, \$datetimeStart: string, \$datetimeEnd: string) {
    viewer {
      zones(filter: {zoneTag: \$zoneTag}) {
        httpRequestsAdaptiveGroups(
          limit: 5000,
          filter: {
            datetime_geq: \$datetimeStart,
            datetime_leq: \$datetimeEnd,
            requestSource: "eyeball",
            OR: [
              {userAgent_like: "%Novellum%"},
              {userAgent_like: "%Anchor Browser%"},
              {userAgent_like: "%Amazonbot%"},
              {userAgent_like: "%Applebot%"},
              {userAgent_like: "%archive.org_bot%"},
              {userAgent_like: "%bingbot%"},
              {userAgent_like: "%Bytespider%"},
              {userAgent_like: "%CCBot%"},
              {userAgent_like: "%ChatGPT-User%"},
              {userAgent_like: "%ClaudeBot%"},
              {userAgent_like: "%Claude-SearchBot%"},
              {userAgent_like: "%Claude-User%"},
              {userAgent_like: "%DuckAssistBot%"},
              {userAgent_like: "%FacebookBot%"},
              {userAgent_like: "%Googlebot%"},
              {userAgent_like: "%Google-CloudVertexBot%"},
              {userAgent_like: "%GPTBot%"},
              {userAgent_like: "%meta-externalagent%"},
              {userAgent_like: "%meta-externalfetcher%"},
              {userAgent_like: "%MistralAI-User%"},
              {userAgent_like: "%OAI-SearchBot%"},
              {userAgent_like: "%PerplexityBot%"},
              {userAgent_like: "%Perplexity-User%"},
              {userAgent_like: "%PetalBot%"},
              {userAgent_like: "%ProRataInc%"},
              {userAgent_like: "%Timpibot%"},
              {userAgent_like: "%Manus-User%"},
              {userAgent_like: "%Terracotta%"},
              {userAgent_like: "%CloudflareBrowserRenderingCrawler%"},
              {userAgent_like: "%TikTokSpider%"},
              {userAgent_like: "%Arquivo-web-crawler%"},
              {userAgent_like: "%Baiduspider%"}
            ]
          }
        ) {
          count
          dimensions {
            datetimeHour
            userAgent
            clientRequestHTTPHost
          }
          sum {
            edgeResponseBytes
          }
        }
      }
    }
  }
END_HEREDOC
      )" \
      --arg zoneTag "$cf_zone_id" \
      --arg datetimeStart "$ISO_CURRENT_DATE_TIME_2H_AGO" \
      --arg datetimeEnd "$ISO_CURRENT_DATE_TIME" \
      '{query: $query, variables: {zoneTag: $zoneTag, datetimeStart: $datetimeStart, datetimeEnd: $datetimeEnd}}'
  )

  cf_ai_crawl_json=$(
    $CURL --silent --fail --show-error --compressed \
      --request POST \
      --header "Content-Type: application/json" \
      --header "$CF_EMAIL_HEADER" \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      --data "$AI_CRAWL_GRAPHQL_QUERY" \
      "$CF_URL"
  )

  cf_ai_crawl_nb_errors=$(echo "$cf_ai_crawl_json" | $JQ '.errors | length')

  if [[ $cf_ai_crawl_nb_errors -gt 0 ]]; then
    cf_ai_crawl_errors=$(echo "$cf_ai_crawl_json" | $JQ --raw-output '.errors[] | .message')
    printf "Cloudflare AI Crawl Control API request failed with: \n%s\nAborting\n" "$cf_ai_crawl_errors" >&2
    exit 1
  fi

  cf_ai_crawl_count=$(echo "$cf_ai_crawl_json" | $JQ '.data.viewer.zones[0].httpRequestsAdaptiveGroups | length')

  if [[ $cf_ai_crawl_count -gt 0 ]]; then
    cf_stats_ai_crawl=$(
      echo "$cf_ai_crawl_json" |
        $JQ --raw-output --arg zone "$cf_zone_domain" '
                    def escape_tag:
                        gsub("\\\\"; "\\\\") |
                        gsub(","; "\\,") |
                        gsub(" "; "\\ ") |
                        gsub("="; "\\=");
                    def tag($name; $value):
                        $name + "=" + ($value | tostring | escape_tag);

                    .data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
                    . as $row |
                    ($row.count // 0) as $requests |
                    ($row.sum.edgeResponseBytes // 0) as $edge_response_bytes |
                    ($row.dimensions.datetimeHour | fromdateiso8601) as $timestamp |
                    "cloudflare_stats_ai_crawl,\(tag("zone"; $zone)),\(tag("crawler"; $row.dimensions.userAgent)),\(tag("host"; $row.dimensions.clientRequestHTTPHost)) requests=\($requests),edgeResponseBytes=\($edge_response_bytes) \($timestamp)"
                '
    )

    echo "$cf_stats_ai_crawl" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --header "Accept: application/json" \
        --data-binary @-
  fi
done

WORKERS_GRAPHQL_QUERY=$(
  $CAT <<END_HEREDOC
{ "query":
  "query GetWorkersAnalytics(\$accountTag: string, \$datetimeStart: string, \$datetimeEnd: string) {
    viewer {
      accounts(filter: {accountTag: \$accountTag}) {
        workersInvocationsAdaptive(limit: 100, filter: {
          datetime_geq: \$datetimeStart,
          datetime_leq: \$datetimeEnd
        }) {
          sum {
            clientDisconnects
            cpuTimeUs
            duration
            errors
            requests
            subrequests
            responseBodySize
            wallTime
          }
          quantiles {
            cpuTimeP50
            cpuTimeP99
            durationP50
            durationP99
            responseBodySizeP50
            responseBodySizeP99
            wallTimeP50
            wallTimeP99
          }
          dimensions{
            datetimeHour
            scriptName
            status
          }
        }
      }
    }
  }",
  "variables": {
    "accountTag": "$CLOUDFLARE_ACCOUNT_TAG",
    "datetimeStart": "$ISO_CURRENT_DATE_TIME_1H_AGO",
    "datetimeEnd": "$ISO_CURRENT_DATE_TIME"
  }
}
END_HEREDOC
)

cf_workers_json=$(
  $CURL --silent --fail --show-error --compressed \
    --request POST \
    --header "Content-Type: application/json" \
    --header "$CF_EMAIL_HEADER" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --data "$(echo -n $WORKERS_GRAPHQL_QUERY)" \
    "$CF_URL"
)

cf_workers_nb_errors=$(echo $cf_workers_json | $JQ ".errors | length")

if [[ $cf_workers_nb_errors -gt 0 ]]; then
  cf_workers_errors=$(echo $cf_workers_json | $JQ --raw-output ".errors[] | .message")
  printf "Cloudflare API request failed with: \n%s\nAborting\n" "$cf_workers_errors" >&2
  exit 1
fi

cf_nb_invocations=$(echo $cf_workers_json | $JQ ".data.viewer.accounts[0].workersInvocationsAdaptive | length")

if [[ $cf_nb_invocations -gt 0 ]]; then
  cf_workers_json_parsed=$(echo $cf_workers_json | $JQ ".data.viewer.accounts[0].workersInvocationsAdaptive")
  cf_stats_workers=$(
    echo "$cf_workers_json_parsed" |
      $JQ --raw-output "
        (.[] |
        [\"${CLOUDFLARE_ACCOUNT_TAG}\",
        .dimensions.scriptName,
        .dimensions.status,
        .quantiles.cpuTimeP50,
        .quantiles.cpuTimeP99,
        .quantiles.durationP50,
        .quantiles.durationP99,
        .quantiles.responseBodySizeP50,
        .quantiles.responseBodySizeP99,
        .quantiles.wallTimeP50,
        .quantiles.wallTimeP99,
        .sum.clientDisconnects,
        .sum.cpuTimeUs,
        .sum.duration,
        .sum.errors,
        .sum.requests,
        .sum.responseBodySize,
        .sum.subrequests,
        .sum.wallTime,
        (.dimensions.datetimeHour | fromdateiso8601)
        ])
        | @tsv" |
      $AWK '{printf "cloudflare_stats_workers,account=%s,worker=%s status=\"%s\",cpuTimeP50=%s,cpuTimeP99=%s,durationP50=%s,durationP99=%s,responseBodySizeP50=%s,responseBodySizeP99=%s,wallTimeP50=%s,wallTimeP99=%s,clientDisconnects=%s,cpuTimeUs=%s,duration=%s,errors=%s,requests=%s,responseBodySize=%s,subrequests=%s,wallTime=%s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20}'
  )

  echo "$cf_stats_workers" | $GZIP |
    $CURL --silent --fail --show-error \
      --request POST "${INFLUXDB_URL}" \
      --header 'Content-Encoding: gzip' \
      --header "Authorization: Token $INFLUXDB_API_TOKEN" \
      --header "Content-Type: text/plain; charset=utf-8" \
      --header "Accept: application/json" \
      --data-binary @-

fi

PAGES_FUNCTIONS_GRAPHQL_QUERY=$(
  $CAT <<END_HEREDOC
{ "query":
  "query {
    viewer {
        accounts(filter: { accountTag: \$accountTag }) {
            pagesFunctionsInvocationsAdaptiveGroups(
                filter: { datetimeHour_geq: \$datetimeStart, datetimeHour_leq: \$datetimeEnd }
                limit: 10000
            ) {
                sum {
                    clientDisconnects
                    duration
                    errors
                    requests
                    responseBodySize
                    subrequests
                    wallTime
                }
                quantiles {
                    cpuTimeP50
                    cpuTimeP99
                    durationP50
                    durationP99
                }
                dimensions {
                    datetimeHour
                    scriptName
                    status
                    usageModel
                }
            }
        }
    }
}",
  "variables": {
    "accountTag": "$CLOUDFLARE_ACCOUNT_TAG",
    "datetimeStart": "$ISO_CURRENT_DATE_TIME_1H_AGO",
    "datetimeEnd": "$ISO_CURRENT_DATE_TIME"
  }
}
END_HEREDOC
)

cf_pf_json=$(
  $CURL --silent --fail --show-error --compressed \
    --request POST \
    --header "Content-Type: application/json" \
    --header "$CF_EMAIL_HEADER" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --data "$(echo -n $PAGES_FUNCTIONS_GRAPHQL_QUERY)" \
    "$CF_URL"
)

cf_pf_nb_errors=$(echo $cf_pf_json | $JQ ".errors | length")

if [[ $cf_pf_nb_errors -gt 0 ]]; then
  cf_pf_errors=$(echo $cf_pf_json | $JQ --raw-output ".errors[] | .message")
  printf "Cloudflare API request failed with: \n%s\nAborting\n" "$cf_pf_errors" >&2
  exit 1
fi

cf_pf_nb_invocations=$(echo $cf_pf_json | $JQ ".data.viewer.accounts[0].pagesFunctionsInvocationsAdaptiveGroups | length")

if [[ $cf_pf_nb_invocations -gt 0 ]]; then
  cf_pf_json_parsed=$(echo $cf_pf_json | $JQ ".data.viewer.accounts[0].pagesFunctionsInvocationsAdaptiveGroups")
  cf_stats_pf=$(
    echo "$cf_pf_json_parsed" |
      $JQ --raw-output "
        (.[] |
        [\"${CLOUDFLARE_ACCOUNT_TAG}\",
        .dimensions.scriptName,
        .dimensions.status,
        .dimensions.usageModel,
        .quantiles.cpuTimeP50,
        .quantiles.cpuTimeP99,
        .quantiles.durationP50,
        .quantiles.durationP99,
        .sum.clientDisconnects,
        .sum.duration,
        .sum.errors,
        .sum.requests,
        .sum.responseBodySize,
        .sum.subrequests,
        .sum.wallTime,
        (.dimensions.datetimeHour | fromdateiso8601)
        ])
        | @tsv" |
      $AWK '{printf "cloudflare_stats_pf,account=%s,scriptName=%s status=\"%s\",usageModel=\"%s\",cpuTimeP50=%s,cpuTimeP99=%s,durationP50=%s,durationP99=%s,clientDisconnects=%s,duration=%s,errors=%s,requests=%s,responseBodySize=%s,subrequests=%s,wallTime=%s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16}'
  )

  echo "$cf_stats_pf" | $GZIP |
    $CURL --silent --fail --show-error \
      --request POST "${INFLUXDB_URL}" \
      --header 'Content-Encoding: gzip' \
      --header "Authorization: Token $INFLUXDB_API_TOKEN" \
      --header "Content-Type: text/plain; charset=utf-8" \
      --header "Accept: application/json" \
      --data-binary @-
fi

if [[ -n "${CLOUDFLARE_KV_NAMESPACES}" ]]; then

  for kv_namespace_id in $(echo "${CLOUDFLARE_KV_NAMESPACES}"); do
    KV_GRAPHQL_QUERY=$(
      $CAT <<END_HEREDOC
{ "query":
  "query {
    viewer {
        accounts(filter: { accountTag: \$accountTag }) {
            kvOperationsAdaptiveGroups(
                filter: { namespaceId: \$namespaceId, datetimeHour_geq: \$datetimeStart, datetimeHour_leq: \$datetimeEnd }
                limit: 10000
            ) {
                sum {
                    objectBytes
                    requests
                }
                quantiles {
                    latencyMsP50
                    latencyMsP99
                }
                dimensions {
                    actionType
                    datetimeHour
                    namespaceId
                    responseStatusCode
                    result
                }
            }
        }
    }
}",
  "variables": {
    "accountTag": "$CLOUDFLARE_ACCOUNT_TAG",
    "namespaceId": "$kv_namespace_id",
    "datetimeStart": "$ISO_CURRENT_DATE_TIME_1H_AGO",
    "datetimeEnd": "$ISO_CURRENT_DATE_TIME"
  }
}
END_HEREDOC
    )

    cf_kv_json=$(
      $CURL --silent --fail --show-error --compressed \
        --request POST \
        --header "Content-Type: application/json" \
        --header "$CF_EMAIL_HEADER" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        --data "$(echo -n $KV_GRAPHQL_QUERY)" \
        "$CF_URL"
    )

    cf_kv_nb_errors=$(echo $cf_kv_json | $JQ ".errors | length")

    if [[ $cf_kv_nb_errors -gt 0 ]]; then
      cf_kv_errors=$(echo $cf_kv_json | $JQ --raw-output ".errors[] | .message")
      printf "Cloudflare API request failed with: \n%s\nAborting\n" "$cf_kv_errors" >&2
      exit 1
    fi

    cf_kv_json_parsed=$(echo $cf_kv_json | $JQ ".data.viewer.accounts[0].kvOperationsAdaptiveGroups")
    cf_stats_kv=$(
      echo "$cf_kv_json_parsed" |
        $JQ --raw-output "
        (.[] |
        [\"${CLOUDFLARE_ACCOUNT_TAG}\",
        .dimensions.namespaceId,
        .dimensions.actionType,
        .dimensions.result,
        .dimensions.responseStatusCode,
        .quantiles.latencyMsP50,
        .quantiles.latencyMsP99,
        .sum.objectBytes,
        .sum.requests,
        (.dimensions.datetimeHour | fromdateiso8601)
        ])
        | @tsv" |
        $AWK '{printf "cloudflare_stats_kv_ops,account=%s,namespace=%s actionType=\"%s\",result=\"%s\",responseStatusCode=%s,latencyMsP50=%s,latencyMsP99=%s,objectBytes=%s,requests=%s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10}'
    )

    echo "$cf_stats_kv" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --header "Accept: application/json" \
        --data-binary @-

    KV_STORAGE_GRAPHQL_QUERY=$(
      $CAT <<END_HEREDOC
{ "query":
  "query {
    viewer {
        accounts(filter: { accountTag: \$accountTag }) {
            kvStorageAdaptiveGroups(
                filter: { namespaceId: \$namespaceId, datetimeHour_geq: \$datetimeStart, datetimeHour_leq: \$datetimeEnd }
                limit: 10000
            ) {
                max {
                    keyCount
                    byteCount
                }
                dimensions {
                    datetimeHour
                    namespaceId
                }
            }
        }
    }
}",
  "variables": {
    "accountTag": "$CLOUDFLARE_ACCOUNT_TAG",
    "namespaceId": "$kv_namespace_id",
    "datetimeStart": "$ISO_CURRENT_DATE_TIME_2H_AGO",
    "datetimeEnd": "$ISO_CURRENT_DATE_TIME"
  }
}
END_HEREDOC
    )

    cf_kv_storage_json=$(
      $CURL --silent --fail --show-error --compressed \
        --request POST \
        --header "Content-Type: application/json" \
        --header "$CF_EMAIL_HEADER" \
        --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        --data "$(echo -n $KV_STORAGE_GRAPHQL_QUERY)" \
        "$CF_URL"
    )

    cf_kv_storage_nb_errors=$(echo $cf_kv_storage_json | $JQ ".errors | length")

    if [[ $cf_kv_storage_nb_errors -gt 0 ]]; then
      cf_kv_storage_errors=$(echo $cf_kv_storage_json | $JQ --raw-output ".errors[] | .message")
      printf "Cloudflare API request failed with: \n%s\nAborting\n" "$cf_kv_storage_errors" >&2
      exit 1
    fi

    cf_kv_storage_json_parsed=$(echo $cf_kv_storage_json | $JQ ".data.viewer.accounts[0].kvStorageAdaptiveGroups")
    cf_stats_kv_storage=$(
      echo "$cf_kv_storage_json_parsed" |
        $JQ --raw-output "
        (.[] |
        [\"${CLOUDFLARE_ACCOUNT_TAG}\",
        .dimensions.namespaceId,
        .max.byteCount,
        .max.keyCount,
        (.dimensions.datetimeHour | fromdateiso8601)
        ])
        | @tsv" |
        $AWK '{printf "cloudflare_stats_kv_storage,account=%s,namespace=%s byteCount=%s,keyCount=%s %s\n", $1, $2, $3, $4, $5}'
    )

    echo "$cf_stats_kv_storage" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --header "Accept: application/json" \
        --data-binary @-
  done

fi

cf_billable_usage_json=$(
  $CURL --silent --fail --show-error --compressed \
    --header "$CF_EMAIL_HEADER" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$CF_BILLABLE_USAGE_URL"
)

cf_billable_usage_success=$(echo "$cf_billable_usage_json" | $JQ --raw-output '.success')

if [[ "$cf_billable_usage_success" != "true" ]]; then
  cf_billable_usage_errors=$(echo "$cf_billable_usage_json" | $JQ --raw-output '.errors[]? | .message // tostring')
  printf "Cloudflare Billable Usage API request failed with: \n%s\nAborting\n" "$cf_billable_usage_errors" >&2
  exit 1
fi

cf_billable_usage_count=$(echo "$cf_billable_usage_json" | $JQ '.result | length')

if [[ $cf_billable_usage_count -gt 0 ]]; then
  cf_stats_billable_usage=$(
    echo "$cf_billable_usage_json" |
      $JQ --raw-output --arg account "$CLOUDFLARE_ACCOUNT_TAG" '
                def escape_tag:
                    gsub("\\\\"; "\\\\") |
                    gsub(","; "\\,") |
                    gsub(" "; "\\ ") |
                    gsub("="; "\\=");
                def tag($name; $value):
                    $name + "=" + ($value | tostring | escape_tag);
                def optional_tag($name; $value):
                    if $value == null or $value == "" then "" else tag($name; $value) end;
                def number_field($name; $value):
                    ($value | try tonumber catch null) as $number |
                    if $number == null then "" else $name + "=" + ($number | tostring) end;

                .result[] |
                . as $row |
                [
                    number_field("consumedQuantity"; $row.ConsumedQuantity),
                    number_field("pricingQuantity"; $row.PricingQuantity),
                    number_field("contractedCost"; $row.ContractedCost),
                    number_field("billedCost"; $row.BilledCost),
                    number_field("effectiveCost"; $row.EffectiveCost),
                    number_field("cumulatedPricingQuantity"; $row.CumulatedPricingQuantity),
                    number_field("cumulatedContractedCost"; $row.CumulatedContractedCost)
                ] | map(select(. != "")) | join(",") as $fields |
                select($fields != "") |
                [
                    tag("account"; $account),
                    optional_tag("billingCurrency"; $row.BillingCurrency),
                    optional_tag("service"; $row.ServiceName // $row.x_BillableMetricName),
                    optional_tag("serviceFamily"; $row.ServiceFamilyName // $row.x_ProductFamilyName),
                    optional_tag("consumedUnit"; $row.ConsumedUnit),
                    optional_tag("zoneId"; $row.ZoneId // $row.x_ZoneId),
                    optional_tag("zone"; $row.ZoneName // $row.x_ZoneName)
                ] | map(select(. != "")) | join(",") as $tags |
                ($row.ChargePeriodStart | fromdateiso8601) as $timestamp |
                "cloudflare_billable_usage,\($tags) \($fields) \($timestamp)"
            '
  )

  echo "$cf_stats_billable_usage" | $GZIP |
    $CURL --silent --fail --show-error \
      --request POST "${INFLUXDB_URL}" \
      --header 'Content-Encoding: gzip' \
      --header "Authorization: Token $INFLUXDB_API_TOKEN" \
      --header "Content-Type: text/plain; charset=utf-8" \
      --header "Accept: application/json" \
      --data-binary @-
fi

D1_QUERY=$(
  $CAT <<'END_HEREDOC'
query GetD1Analytics($accountTag: string, $date: Date, $datetimeStart: Time, $datetimeEnd: Time) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      d1AnalyticsAdaptiveGroups(limit: 10000, filter: {date_geq: $date, date_leq: $date}) {
        sum { readQueries writeQueries rowsRead rowsWritten queryBatchResponseBytes }
        avg { queryBatchTimeMs }
        quantiles { queryBatchTimeMsP90 }
        dimensions { date databaseId }
      }
      d1StorageAdaptiveGroups(limit: 10000, filter: {date_geq: $date, date_leq: $date}) {
        max { databaseSizeBytes }
        dimensions { date databaseId }
      }
      d1QueriesAdaptiveGroups(limit: 10000, filter: {datetimeFiveMinutes_geq: $datetimeStart, datetimeFiveMinutes_leq: $datetimeEnd}) {
        count
        sum { rowsRead rowsWritten }
        quantiles { queryDurationMsP50 queryDurationMsP95 queryDurationMsP99 }
        dimensions { datetimeFiveMinutes databaseId servedByRegion databaseRole }
      }
    }
  }
}
END_HEREDOC
)
D1_PAYLOAD=$(
  $JQ --null-input --compact-output \
    --arg query "$D1_QUERY" \
    --arg accountTag "$CLOUDFLARE_ACCOUNT_TAG" \
    --arg date "$RFC_CURRENT_DATE" \
    --arg datetimeStart "$ISO_CURRENT_DATE_TIME_2H_AGO" \
    --arg datetimeEnd "$ISO_CURRENT_DATE_TIME" \
    '{query: $query, variables: {accountTag: $accountTag, date: $date, datetimeStart: $datetimeStart, datetimeEnd: $datetimeEnd}}'
)
d1_json=$(
  $CURL --silent --fail --show-error --compressed \
    --request POST \
    --header "Content-Type: application/json" \
    --header "$CF_EMAIL_HEADER" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --data "$D1_PAYLOAD" \
    "$CF_URL"
)
[[ $(echo "$d1_json" | $JQ '.errors | length') -gt 0 ]] && echo "$d1_json" | $JQ --raw-output '.errors[] | .message' >&2 && exit 1
d1_stats=$(echo "$d1_json" | $JQ -r --arg account "$CLOUDFLARE_ACCOUNT_TAG" '
  def date_timestamp: . + "T00:00:00Z" | fromdateiso8601;
  .data.viewer.accounts[0] as $a |
  ($a.d1AnalyticsAdaptiveGroups[]? | "cloudflare_stats_d1,account=\($account),database=\(.dimensions.databaseId) readQueries=\(.sum.readQueries // 0),writeQueries=\(.sum.writeQueries // 0),rowsRead=\(.sum.rowsRead // 0),rowsWritten=\(.sum.rowsWritten // 0),queryBatchResponseBytes=\(.sum.queryBatchResponseBytes // 0),queryBatchTimeMs=\(.avg.queryBatchTimeMs // 0),queryBatchTimeMsP90=\(.quantiles.queryBatchTimeMsP90 // 0) \(.dimensions.date | date_timestamp)"),
  ($a.d1StorageAdaptiveGroups[]? | "cloudflare_stats_d1_storage,account=\($account),database=\(.dimensions.databaseId) databaseSizeBytes=\(.max.databaseSizeBytes // 0) \(.dimensions.date | date_timestamp)"),
  ($a.d1QueriesAdaptiveGroups[]? | "cloudflare_stats_d1_queries,account=\($account),database=\(.dimensions.databaseId),region=\(.dimensions.servedByRegion),role=\(.dimensions.databaseRole) queries=\(.count // 0),rowsRead=\(.sum.rowsRead // 0),rowsWritten=\(.sum.rowsWritten // 0),queryDurationMsP50=\(.quantiles.queryDurationMsP50 // 0),queryDurationMsP95=\(.quantiles.queryDurationMsP95 // 0),queryDurationMsP99=\(.quantiles.queryDurationMsP99 // 0) \(.dimensions.datetimeFiveMinutes | fromdateiso8601)")')
if [[ -n "$d1_stats" ]]; then
  echo "$d1_stats" | $GZIP |
    $CURL --silent --fail --show-error \
      --request POST "${INFLUXDB_URL}" \
      --header 'Content-Encoding: gzip' \
      --header "Authorization: Token $INFLUXDB_API_TOKEN" \
      --header 'Content-Type: text/plain; charset=utf-8' \
      --data-binary @-
fi

R2_QUERY=$(
  $CAT <<'END_HEREDOC'
query GetR2Analytics($accountTag: string, $start: Time, $end: Time) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      r2OperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
        sum { requests responseBytes }
        dimensions { datetime date bucketName actionType actionStatus responseStatusCode storageClass }
      }
      r2StorageAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
        max { objectCount uploadCount payloadSize metadataSize }
        dimensions { datetime date bucketName storageClass }
      }
    }
  }
}
END_HEREDOC
)
R2_PAYLOAD=$(
  $JQ --null-input --compact-output \
    --arg query "$R2_QUERY" \
    --arg accountTag "$CLOUDFLARE_ACCOUNT_TAG" \
    --arg start "$ISO_CURRENT_DATE_TIME_2H_AGO" \
    --arg end "$ISO_CURRENT_DATE_TIME" \
    '{query: $query, variables: {accountTag: $accountTag, start: $start, end: $end}}'
)
r2_json=$(
  $CURL --silent --fail --show-error --compressed \
    --request POST \
    --header "Content-Type: application/json" \
    --header "$CF_EMAIL_HEADER" \
    --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    --data "$R2_PAYLOAD" \
    "$CF_URL"
)
[[ $(echo "$r2_json" | $JQ '.errors | length') -gt 0 ]] && echo "$r2_json" | $JQ --raw-output '.errors[] | .message' >&2 && exit 1
r2_stats=$(echo "$r2_json" | $JQ -r --arg account "$CLOUDFLARE_ACCOUNT_TAG" '
  .data.viewer.accounts[0] as $a |
  ($a.r2OperationsAdaptiveGroups[]? | "cloudflare_stats_r2_operations,account=\($account),bucket=\(.dimensions.bucketName),storageClass=\(.dimensions.storageClass),actionType=\(.dimensions.actionType),actionStatus=\(.dimensions.actionStatus),responseStatusCode=\(.dimensions.responseStatusCode) requests=\(.sum.requests // 0),responseBytes=\(.sum.responseBytes // 0) \(.dimensions.datetime | fromdateiso8601)"),
  ($a.r2StorageAdaptiveGroups[]? | "cloudflare_stats_r2_storage,account=\($account),bucket=\(.dimensions.bucketName),storageClass=\(.dimensions.storageClass) objectCount=\(.max.objectCount // 0),uploadCount=\(.max.uploadCount // 0),payloadSize=\(.max.payloadSize // 0),metadataSize=\(.max.metadataSize // 0) \(.dimensions.datetime | fromdateiso8601)")')
if [[ -n "$r2_stats" ]]; then
  echo "$r2_stats" | $GZIP |
    $CURL --silent --fail --show-error \
      --request POST "${INFLUXDB_URL}" \
      --header 'Content-Encoding: gzip' \
      --header "Authorization: Token $INFLUXDB_API_TOKEN" \
      --header 'Content-Type: text/plain; charset=utf-8' \
      --data-binary @-
fi

# Email Service is zone-scoped, so run the same aggregate query for every discovered zone.
for i in $(seq 0 "$nb_zones"); do
  mapfile -t email_zone < <(echo "$CLOUDFLARE_ZONE_LIST" | $JQ --raw-output ".[${i}] | .id, .domain")
  EMAIL_QUERY=$(
    $CAT <<'END_HEREDOC'
query GetEmailServiceAnalytics($zoneTag: string, $start: Time, $end: Time) {
  viewer {
    zones(filter: {zoneTag: $zoneTag}) {
      emailSendingAdaptiveGroups(limit: 10000, filter: {datetimeHour_geq: $start, datetimeHour_leq: $end}) {
        count
        dimensions { datetimeHour status eventType sendingDomain }
      }
      emailRoutingAdaptiveGroups(limit: 10000, filter: {datetimeHour_geq: $start, datetimeHour_leq: $end}) {
        count
        dimensions { datetimeHour status eventType action ruleMatched }
      }
    }
  }
}
END_HEREDOC
  )
  EMAIL_PAYLOAD=$(
    $JQ --null-input --compact-output \
      --arg query "$EMAIL_QUERY" \
      --arg zoneTag "${email_zone[0]}" \
      --arg start "$ISO_CURRENT_DATE_TIME_2H_AGO" \
      --arg end "$ISO_CURRENT_DATE_TIME" \
      '{query: $query, variables: {zoneTag: $zoneTag, start: $start, end: $end}}'
  )
  email_json=$(
    $CURL --silent --fail --show-error --compressed \
      --request POST \
      --header "Content-Type: application/json" \
      --header "$CF_EMAIL_HEADER" \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      --data "$EMAIL_PAYLOAD" \
      "$CF_URL"
  )
  [[ $(echo "$email_json" | $JQ '.errors | length') -gt 0 ]] && echo "$email_json" | $JQ --raw-output '.errors[] | .message' >&2 && exit 1
  email_stats=$(echo "$email_json" | $JQ -r --arg zone "${email_zone[1]}" '
      .data.viewer.zones[0] as $z |
      ($z.emailSendingAdaptiveGroups[]? | "cloudflare_stats_email_sending,zone=\($zone),status=\(.dimensions.status),eventType=\(.dimensions.eventType),sendingDomain=\(.dimensions.sendingDomain) emails=\(.count // 0) \(.dimensions.datetimeHour | fromdateiso8601)"),
      ($z.emailRoutingAdaptiveGroups[]? | "cloudflare_stats_email_routing,zone=\($zone),status=\(.dimensions.status),eventType=\(.dimensions.eventType),action=\(.dimensions.action),ruleMatched=\(.dimensions.ruleMatched) emails=\(.count // 0) \(.dimensions.datetimeHour | fromdateiso8601)")')
  if [[ -n "$email_stats" ]]; then
    echo "$email_stats" | $GZIP |
      $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header 'Content-Type: text/plain; charset=utf-8' \
        --data-binary @-
  fi
done
