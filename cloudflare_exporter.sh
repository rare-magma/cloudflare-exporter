#!/usr/bin/env bash

set -Eeo pipefail

dependencies=(cat curl date gzip jq)
for program in "${dependencies[@]}"; do
    command -v "$program" >/dev/null 2>&1 || {
        echo >&2 "Couldn't find dependency: $program. Aborting."
        exit 1
    }
done

CAT=$(command -v cat)
CURL=$(command -v curl)
DATE=$(command -v date)
GZIP=$(command -v gzip)
JQ=$(command -v jq)

if [[ "${RUNNING_IN_DOCKER}" ]]; then
    source "/app/cloudflare_exporter.conf"
    CLOUDFLARE_ZONE_LIST=$($CAT /app/cloudflare_zone_list.json)
else
    #shellcheck source=/dev/null
    source "$CREDENTIALS_DIRECTORY/creds"
    CLOUDFLARE_ZONE_LIST=$($CAT $CREDENTIALS_DIRECTORY/list)
fi

[[ -z "${INFLUXDB_HOST}" ]] && echo >&2 "INFLUXDB_HOST is empty. Aborting" && exit 1
[[ -z "${INFLUXDB_API_TOKEN}" ]] && echo >&2 "INFLUXDB_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${ORG}" ]] && echo >&2 "ORG is empty. Aborting" && exit 1
[[ -z "${BUCKET}" ]] && echo >&2 "BUCKET is empty. Aborting" && exit 1
[[ -z "${CLOUDFLARE_API_TOKEN}" ]] && echo >&2 "CLOUDFLARE_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${CLOUDFLARE_ZONE_LIST}" ]] && echo >&2 "CLOUDFLARE_ZONE_LIST is empty. Aborting" && exit 1
[[ $(echo "${CLOUDFLARE_ZONE_LIST}" | $JQ type 1>/dev/null) ]] && echo >&2 "CLOUDFLARE_ZONE_LIST is not valid JSON. Aborting" && exit 1
[[ -n "${CLOUDFLARE_ACCOUNT_EMAIL}" ]] && CF_EMAIL_HEADER="X-Auth-Email: ${CLOUDFLARE_ACCOUNT_EMAIL}"

RFC_CURRENT_DATE=$($DATE --rfc-3339=date)
INFLUXDB_URL="https://$INFLUXDB_HOST/api/v2/write?precision=s&org=$ORG&bucket=$BUCKET"
CF_URL="https://api.cloudflare.com/client/v4/graphql"

nb_zones=$(echo "$CLOUDFLARE_ZONE_LIST" | $JQ 'length - 1')

for i in $(seq 0 "$nb_zones"); do

    mapfile -t cf_zone < <(echo "$CLOUDFLARE_ZONE_LIST" | $JQ --raw-output ".[${i}] | .id, .domain")
    cf_zone_id=${cf_zone[0]}
    cf_zone_domain="${cf_zone[1]}"

    GRAPHQL_QUERY=$(
        cat <<END_HEREDOC
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
done
