package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	cloudflareAPI = "https://api.cloudflare.com/client/v4"
	retryCount    = 3
)

const queuesQuery = `
query GetQueuesAnalytics(
  $accountTag: string
  $queueId: string
  $datetimeStart: Time
  $datetimeEnd: Time
	) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      queueBacklogAdaptiveGroups(
        limit: 10000
        filter: {
          queueId: $queueId
          datetime_geq: $datetimeStart
          datetime_leq: $datetimeEnd
        }
      ) {
        avg {
          bytes
          messages
        }
        dimensions {
          datetimeMinute
          queueId
        }
      }
      queueDelayedBacklogAdaptiveGroups(
        limit: 10000
        filter: {
          queueId: $queueId
          datetime_geq: $datetimeStart
          datetime_leq: $datetimeEnd
        }
      ) {
        avg {
          messages
        }
        dimensions {
          datetimeMinute
          queueId
        }
      }
      queueConsumerMetricsAdaptiveGroups(
        limit: 10000
        filter: {
          queueId: $queueId
          datetime_geq: $datetimeStart
          datetime_leq: $datetimeEnd
        }
      ) {
        avg {
          concurrency
        }
        dimensions {
          datetimeMinute
          queueId
        }
      }
      queueMessageOperationsAdaptiveGroups(
        limit: 10000
        filter: {
          queueId: $queueId
          datetime_geq: $datetimeStart
          datetime_leq: $datetimeEnd
        }
      ) {
        count
        sum {
          bytes
          billableOperations
        }
        avg {
          retryCount
          lagTime
        }
        dimensions {
          datetimeMinute
          queueId
          actionType
          consumerType
          outcome
        }
      }
    }
  }
}`

const zonesQuery = `
query ZoneHourly($zoneTag: string, $date: Date) {
 viewer {
   zones(filter: { zoneTag: $zoneTag }) {
     httpRequests1hGroups(
       limit: 7
       filter: { date_geq: $date, date_leq: $date }
     ) {
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
}`

const aiCrawlQuery = `
query AICrawl($zoneTag: string, $start: string, $end: string) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      httpRequestsAdaptiveGroups(
        limit: 5000
        filter: {
          datetime_geq: $start
          datetime_leq: $end
          requestSource: "eyeball"
          OR: [
            { userAgent_like: "%Novellum%" }
            { userAgent_like: "%Anchor Browser%" }
            { userAgent_like: "%Amazonbot%" }
            { userAgent_like: "%Applebot%" }
            { userAgent_like: "%archive.org_bot%" }
            { userAgent_like: "%bingbot%" }
            { userAgent_like: "%Bytespider%" }
            { userAgent_like: "%CCBot%" }
            { userAgent_like: "%ChatGPT-User%" }
            { userAgent_like: "%ClaudeBot%" }
            { userAgent_like: "%Claude-SearchBot%" }
            { userAgent_like: "%Claude-User%" }
            { userAgent_like: "%DuckAssistBot%" }
            { userAgent_like: "%FacebookBot%" }
            { userAgent_like: "%Googlebot%" }
            { userAgent_like: "%Google-CloudVertexBot%" }
            { userAgent_like: "%GPTBot%" }
            { userAgent_like: "%meta-externalagent%" }
            { userAgent_like: "%meta-externalfetcher%" }
            { userAgent_like: "%MistralAI-User%" }
            { userAgent_like: "%OAI-SearchBot%" }
            { userAgent_like: "%PerplexityBot%" }
            { userAgent_like: "%Perplexity-User%" }
            { userAgent_like: "%PetalBot%" }
            { userAgent_like: "%ProRataInc%" }
            { userAgent_like: "%Timpibot%" }
            { userAgent_like: "%Manus-User%" }
            { userAgent_like: "%Terracotta%" }
            { userAgent_like: "%CloudflareBrowserRenderingCrawler%" }
            { userAgent_like: "%TikTokSpider%" }
            { userAgent_like: "%Arquivo-web-crawler%" }
            { userAgent_like: "%Baiduspider%" }
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
}`

const workersQuery = `
query Workers($accountTag: string, $start: string, $end: string) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      workersInvocationsAdaptive(
        limit: 100
        filter: { datetime_geq: $start, datetime_leq: $end }
      ) {
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
        dimensions {
          datetimeHour
          scriptName
          status
        }
      }
      pagesFunctionsInvocationsAdaptiveGroups(
        limit: 10000
        filter: { datetimeHour_geq: $start, datetimeHour_leq: $end }
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
}`

const kvQuery = `
query KV(
  $accountTag: string
  $namespaceId: string
  $one: Time
  $two: Time
  $end: Time
	) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      kvOperationsAdaptiveGroups(
        limit: 10000
        filter: {
          namespaceId: $namespaceId
          datetimeHour_geq: $one
          datetimeHour_leq: $end
        }
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
      kvStorageAdaptiveGroups(
        limit: 10000
        filter: {
          namespaceId: $namespaceId
          datetimeHour_geq: $two
          datetimeHour_leq: $end
        }
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
}`

const d1Query = `
query D1($accountTag: string, $date: Date, $start: Time, $end: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      d1AnalyticsAdaptiveGroups(
        limit: 10000
        filter: { date_geq: $date, date_leq: $date }
      ) {
        sum {
          readQueries
          writeQueries
          rowsRead
          rowsWritten
          queryBatchResponseBytes
        }
        avg {
          queryBatchTimeMs
        }
        quantiles {
          queryBatchTimeMsP90
        }
        dimensions {
          date
          databaseId
        }
      }
      d1StorageAdaptiveGroups(
        limit: 10000
        filter: { date_geq: $date, date_leq: $date }
      ) {
        max {
          databaseSizeBytes
        }
        dimensions {
          date
          databaseId
        }
      }
      d1QueriesAdaptiveGroups(
        limit: 10000
        filter: {
          datetimeFiveMinutes_geq: $start
          datetimeFiveMinutes_leq: $end
        }
      ) {
        count
        sum {
          rowsRead
          rowsWritten
        }
        quantiles {
          queryDurationMsP50
          queryDurationMsP95
          queryDurationMsP99
        }
        dimensions {
          datetimeFiveMinutes
          databaseId
          servedByRegion
          databaseRole
        }
      }
    }
  }
}`

const r2Query = `
query R2($accountTag: string, $start: Time, $end: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      r2OperationsAdaptiveGroups(
        limit: 10000
        filter: { datetime_geq: $start, datetime_leq: $end }
      ) {
        sum {
          requests
          responseBytes
        }
        dimensions {
          datetime
          bucketName
          actionType
          actionStatus
          responseStatusCode
          storageClass
        }
      }
      r2StorageAdaptiveGroups(
        limit: 10000
        filter: { datetime_geq: $start, datetime_leq: $end }
      ) {
        max {
          objectCount
          uploadCount
          payloadSize
          metadataSize
        }
        dimensions {
          datetime
          bucketName
          storageClass
        }
      }
    }
  }
}`

const emailQuery = `
query Email($zoneTag: string, $start: Time, $end: Time) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      emailSendingAdaptiveGroups(
        limit: 10000
        filter: { datetimeHour_geq: $start, datetimeHour_leq: $end }
      ) {
        count
        dimensions {
          datetimeHour
          status
          eventType
          sendingDomain
        }
      }
      emailRoutingAdaptiveGroups(
        limit: 10000
        filter: { datetimeHour_geq: $start, datetimeHour_leq: $end }
      ) {
        count
        dimensions {
          datetimeHour
          status
          eventType
          action
          ruleMatched
        }
      }
    }
  }
}`

type Config struct {
	InfluxDBHost           string `json:"InfluxDBHost"`
	InfluxDBApiToken       string `json:"InfluxDBApiToken"`
	Org                    string `json:"Org"`
	Bucket                 string `json:"Bucket"`
	CloudflareApiToken     string `json:"CloudflareApiToken"`
	CloudflareAccountEmail string `json:"CloudflareAccountEmail"`
	CloudflareAccountTag   string `json:"CloudflareAccountTag"`
}

type retryableTransport struct {
	transport             http.RoundTripper
	TLSHandshakeTimeout   time.Duration
	ResponseHeaderTimeout time.Duration
}

func shouldRetry(err error, resp *http.Response) bool {
	if err != nil || resp == nil {
		return true
	}
	switch resp.StatusCode {
	case http.StatusTooManyRequests,
		http.StatusInternalServerError,
		http.StatusBadGateway,
		http.StatusServiceUnavailable,
		http.StatusGatewayTimeout:
		return true
	default:
		return false
	}
}

func (t *retryableTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	var bodyBytes []byte
	if req.Body != nil {
		bodyBytes, _ = io.ReadAll(req.Body)
		req.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
	}
	resp, err := t.transport.RoundTrip(req)
	retries := 0
	for shouldRetry(err, resp) && retries < retryCount {
		backoff := time.Duration(math.Pow(2, float64(retries))) * time.Second * 10
		time.Sleep(backoff)
		if resp != nil && resp.Body != nil {
			if _, err := io.Copy(io.Discard, resp.Body); err != nil {
				log.Printf("discarding retry response body: %v", err)
			}
			if err := resp.Body.Close(); err != nil {
				log.Printf("closing retry response body: %v", err)
			}
		}
		if req.Body != nil {
			req.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		}
		if resp != nil && resp.Status != "" {
			log.Printf("Previous request failed with %s", resp.Status)
		}
		log.Printf("Retry %d of request to: %s", retries+1, req.URL)
		resp, err = t.transport.RoundTrip(req)
		retries++
	}
	return resp, err
}

type apiError struct {
	Message string `json:"message"`
}

type restEnvelope struct {
	Success    bool            `json:"success"`
	Result     json.RawMessage `json:"result"`
	ResultInfo struct {
		TotalPages int `json:"total_pages"`
	} `json:"result_info"`
	Errors []apiError `json:"errors"`
}

type gqlEnvelope struct {
	Data   json.RawMessage `json:"data"`
	Errors []apiError      `json:"errors"`
}

type zone struct {
	ID     string `json:"id"`
	Domain string `json:"name"`
}

type namespace struct {
	ID string
}

type queue struct {
	ID string `json:"queue_id"`
}

type exporter struct {
	config    Config
	client    *http.Client
	payload   bytes.Buffer
	payloadMu sync.Mutex
	now       time.Time
}

func loadConfig() Config {
	confFilePath := "cloudflare_exporter.json"
	confData, err := os.Open(confFilePath)
	if err != nil {
		log.Fatalln("Error reading config file: ", err)
	}
	defer func() {
		if err := confData.Close(); err != nil {
			log.Printf("closing config file: %v", err)
		}
	}()
	var c Config
	if err := json.NewDecoder(confData).Decode(&c); err != nil {
		log.Fatalf("invalid configuration: %v", err)
	}
	for name, value := range map[string]string{
		"InfluxDBHost":         c.InfluxDBHost,
		"InfluxDBApiToken":     c.InfluxDBApiToken,
		"Org":                  c.Org,
		"Bucket":               c.Bucket,
		"CloudflareApiToken":   c.CloudflareApiToken,
		"CloudflareAccountTag": c.CloudflareAccountTag,
	} {
		if strings.TrimSpace(value) == "" {
			log.Fatalf("%s is required", name)
		}
	}
	return c
}

func (e *exporter) request(method, endpoint string, body io.Reader, graphql bool) []byte {
	req, err := http.NewRequest(method, endpoint, body)
	if err != nil {
		log.Fatalf("creating Cloudflare request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+e.config.CloudflareApiToken)
	if e.config.CloudflareAccountEmail != "" {
		req.Header.Set("X-Auth-Email", e.config.CloudflareAccountEmail)
	}
	if graphql {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := e.client.Do(req)
	if err != nil {
		log.Fatalf("Cloudflare request: %v", err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.Printf("closing Cloudflare response body: %v", err)
		}
	}()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("reading Cloudflare response: %v", err)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		log.Fatalf("Cloudflare request failed: %s: %s", resp.Status, data)
	}
	return data
}

func (e *exporter) rest(endpoint string, out any) int {
	body := e.request(http.MethodGet, endpoint, nil, false)
	var env restEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		log.Fatalf("decoding Cloudflare REST response: %v", err)
	}
	if !env.Success {
		messages := make([]string, 0, len(env.Errors))
		for _, apiErr := range env.Errors {
			messages = append(messages, apiErr.Message)
		}
		log.Fatalf("Cloudflare REST API request failed: %s", strings.Join(messages, "; "))
	}
	if err := json.Unmarshal(env.Result, out); err != nil {
		log.Fatalf("decoding Cloudflare REST result: %v", err)
	}
	return env.ResultInfo.TotalPages
}

func (e *exporter) gql(query string, variables map[string]string) json.RawMessage {
	body, err := json.Marshal(struct {
		Query     string            `json:"query"`
		Variables map[string]string `json:"variables"`
	}{query, variables})
	if err != nil {
		log.Fatalf("encoding GraphQL request: %v", err)
	}
	result := e.request(http.MethodPost, cloudflareAPI+"/graphql", bytes.NewBuffer(body), true)
	var env gqlEnvelope
	if err := json.Unmarshal(result, &env); err != nil {
		log.Fatalf("decoding GraphQL response: %v", err)
	}
	if len(env.Errors) > 0 {
		messages := make([]string, 0, len(env.Errors))
		for _, apiErr := range env.Errors {
			messages = append(messages, apiErr.Message)
		}
		log.Fatalf("Cloudflare GraphQL API request failed: %s", strings.Join(messages, "; "))
	}
	return env.Data
}

func (e *exporter) zones() []zone {
	var all []zone
	for page := 1; ; page++ {
		var v []zone
		pages := e.rest(
			fmt.Sprintf(
				"%s/zones?account.id=%s&page=%d&per_page=50",
				cloudflareAPI,
				url.QueryEscape(e.config.CloudflareAccountTag),
				page,
			),
			&v,
		)
		all = append(all, v...)
		if pages == 0 || page >= pages {
			break
		}
	}
	if len(all) == 0 {
		log.Fatalln("no Cloudflare zones found")
	}
	return all
}

func (e *exporter) namespaces() []string {
	var all []string
	for page := 1; ; page++ {
		var v []namespace
		pages := e.rest(
			fmt.Sprintf(
				"%s/accounts/%s/storage/kv/namespaces?page=%d&per_page=1000",
				cloudflareAPI,
				url.PathEscape(e.config.CloudflareAccountTag),
				page,
			),
			&v,
		)
		for _, x := range v {
			if x.ID != "" {
				all = append(all, x.ID)
			}
		}
		if pages == 0 || page >= pages {
			return all
		}
	}
}

func (e *exporter) queues() []string {
	var all []string
	for page := 1; ; page++ {
		var v []queue
		pages := e.rest(
			fmt.Sprintf(
				"%s/accounts/%s/queues?page=%d&per_page=1000",
				cloudflareAPI,
				url.PathEscape(e.config.CloudflareAccountTag),
				page,
			),
			&v,
		)
		for _, x := range v {
			if x.ID != "" {
				all = append(all, x.ID)
			}
		}
		if pages == 0 || page >= pages {
			return all
		}
	}
}

func object(v json.RawMessage) map[string]json.RawMessage {
	if len(v) == 0 || string(v) == "null" {
		return map[string]json.RawMessage{}
	}
	var o map[string]json.RawMessage
	if err := json.Unmarshal(v, &o); err != nil {
		log.Fatalf("decoding GraphQL object: %v", err)
	}
	return o
}

func array(v json.RawMessage) []json.RawMessage {
	var a []json.RawMessage
	if len(v) == 0 || string(v) == "null" {
		return nil
	}
	if err := json.Unmarshal(v, &a); err != nil {
		log.Fatalf("decoding GraphQL array: %v", err)
	}
	return a
}

func account(data json.RawMessage) map[string]json.RawMessage {
	v := object(data)
	v = object(v["viewer"])
	a := array(v["accounts"])
	if len(a) == 0 {
		return map[string]json.RawMessage{}
	}
	return object(a[0])
}

func zoneData(data json.RawMessage) map[string]json.RawMessage {
	v := object(data)
	v = object(v["viewer"])
	a := array(v["zones"])
	if len(a) == 0 {
		return map[string]json.RawMessage{}
	}
	return object(a[0])
}

func stringAt(o map[string]json.RawMessage, groups ...string) string {
	var v json.RawMessage
	for i, k := range groups {
		if i == 0 {
			v = o[k]
		} else {
			v = object(v)[k]
		}
	}
	var s string
	if len(v) == 0 || string(v) == "null" {
		return ""
	}
	if err := json.Unmarshal(v, &s); err == nil {
		return s
	}
	return strings.Trim(string(v), `"`)
}

func unix(value string) int64 {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02"} {
		if t, err := time.Parse(layout, value); err == nil {
			return t.Unix()
		}
	}
	log.Fatalf("invalid Cloudflare timestamp %q", value)
	return 0
}

type pair struct {
	key, value string
	optional   bool
}

func (e *exporter) line(measurement string, tags []pair, fields []pair, timestamp int64) {
	t := make([]string, 0, len(tags))
	for _, x := range tags {
		if x.optional && x.value == "" {
			continue
		}
		escapedValue := strings.NewReplacer(`\`, `\\`, `,`, `\,`, `=`, `\=`, ` `, `\ `).Replace(x.value)
		t = append(t, x.key+"="+escapedValue)
	}
	f := make([]string, 0, len(fields))
	for _, x := range fields {
		if x.optional && x.value == "" {
			continue
		}
		f = append(f, x.key+"="+x.value)
	}
	if len(f) == 0 {
		return
	}
	line := measurement
	if len(t) > 0 {
		line += "," + strings.Join(t, ",")
	}
	line += " " + strings.Join(f, ",") + fmt.Sprintf(" %d\n", timestamp)
	e.payloadMu.Lock()
	defer e.payloadMu.Unlock()
	if _, err := e.payload.WriteString(line); err != nil {
		log.Fatalf("buffering line protocol: %v", err)
	}
}

func tags(values ...string) []pair {
	p := make([]pair, 0, len(values)/2)
	for i := 0; i < len(values); i += 2 {
		p = append(p, pair{values[i], values[i+1], false})
	}
	return p
}

func numeric(name string, o map[string]json.RawMessage, groups ...string) pair {
	var value json.RawMessage
	for i, key := range groups {
		if i == 0 {
			value = o[key]
		} else {
			value = object(value)[key]
		}
	}
	if len(value) == 0 || string(value) == "null" {
		return pair{name, "0", false}
	}
	var number json.Number
	if err := json.Unmarshal(value, &number); err != nil {
		log.Fatalf("invalid numeric value for %s: %v", strings.Join(groups, "."), err)
	}
	if _, err := strconv.ParseFloat(number.String(), 64); err != nil {
		log.Fatalf("invalid numeric value %q: %v", number, err)
	}
	return pair{name, number.String(), false}
}

func (e *exporter) collectQueues(datetimeStart, datetimeEnd string) {
	var wg sync.WaitGroup
	for _, id := range e.queues() {
		wg.Go(func() {
			a := account(
				e.gql(
					queuesQuery,
					map[string]string{
						"accountTag":    e.config.CloudflareAccountTag,
						"queueId":       id,
						"datetimeStart": datetimeStart,
						"datetimeEnd":   datetimeEnd,
					},
				),
			)
			for _, spec := range []struct {
				name, dataset string
				fields        [][]string
				optional      []string
			}{
				{
					"cloudflare_stats_queue_backlog",
					"queueBacklogAdaptiveGroups",
					[][]string{
						{"avg", "bytes"},
						{"avg", "messages"},
					},
					nil,
				},
				{
					"cloudflare_stats_queue_delayed_backlog", "queueDelayedBacklogAdaptiveGroups",
					[][]string{
						{"avg", "messages"},
					},
					nil,
				},
				{
					"cloudflare_stats_queue_consumers", "queueConsumerMetricsAdaptiveGroups",
					[][]string{
						{"avg", "concurrency"},
					},
					nil,
				},
				{
					"cloudflare_stats_queue_operations", "queueMessageOperationsAdaptiveGroups",
					[][]string{
						{"operations", "count"},
						{"sum", "billableOperations"},
						{"sum", "bytes"},
						{"avg", "retryCount"},
						{"avg", "lagTime"},
					},
					[]string{"actionType", "consumerType", "outcome"},
				},
			} {
				for _, r := range array(a[spec.dataset]) {
					row := object(r)
					d := object(row["dimensions"])
					ts := unix(stringAt(d, "datetimeMinute"))
					tt := tags(
						"account",
						e.config.CloudflareAccountTag,
						"queue",
						stringAt(d, "queueId"),
					)
					for _, k := range spec.optional {
						if v := stringAt(d, k); v != "" {
							tt = append(tt, pair{k, v, false})
						}
					}
					fs := make([]pair, 0, len(spec.fields))
					for _, path := range spec.fields {
						if path[0] == "operations" {
							fs = append(fs, numeric("operations", row, "count"))
						} else {
							fs = append(fs, numeric(path[len(path)-1], row, path...))
						}
					}
					e.line(spec.name, tt, fs, ts)
				}
			}
		})
	}
	wg.Wait()
}

func (e *exporter) collectZoneHourly(z zone, date string) {
	zdata := zoneData(e.gql(zonesQuery, map[string]string{"zoneTag": z.ID, "date": date}))
	for _, r := range array(zdata["httpRequests1hGroups"]) {
		row := object(r)
		sum := object(row["sum"])
		ts := unix(stringAt(object(row["dimensions"]), "datetime"))
		base := tags("zone", z.Domain)
		for _, x := range array(sum["browserMap"]) {
			o := object(x)
			e.line("cloudflare_stats_browser",
				append(
					base,
					pair{
						"browserFamily",
						stringAt(o, "uaBrowserFamily"), false,
					}),
				[]pair{numeric("pageViews", o, "pageViews")}, ts)
		}
		for _, x := range array(sum["contentTypeMap"]) {
			o := object(x)
			e.line(
				"cloudflare_stats_content_type",
				append(
					base,
					pair{"edgeResponse", stringAt(o, "edgeResponseContentTypeName"), false},
				),
				[]pair{numeric("bytes", o, "bytes"), numeric("requests", o, "requests")},
				ts,
			)
		}
		for _, x := range array(sum["countryMap"]) {
			o := object(x)
			e.line(
				"cloudflare_stats_countries",
				append(base, pair{"country", stringAt(o, "clientCountryName"), false}),
				[]pair{
					numeric("bytes", o, "bytes"),
					numeric("requests", o, "requests"),
					numeric("threats", o, "threats"),
				},
				ts,
			)
		}
		for _, x := range array(sum["ipClassMap"]) {
			o := object(x)
			e.line(
				"cloudflare_stats_ip",
				append(base, pair{"ipType", stringAt(o, "ipType"), false}),
				[]pair{numeric("requests", o, "requests")},
				ts,
			)
		}
		for _, x := range array(sum["responseStatusMap"]) {
			o := object(x)
			e.line(
				"cloudflare_stats_responses",
				append(base, pair{"status", stringAt(o, "edgeResponseStatus"), false}),
				[]pair{numeric("requests", o, "requests")},
				ts,
			)
		}
		for _, x := range array(sum["threatPathingMap"]) {
			o := object(x)
			e.line(
				"cloudflare_stats_threats",
				append(base, pair{"threat", stringAt(o, "threatPathingName"), false}),
				[]pair{numeric("requests", o, "requests")},
				ts,
			)
		}
		e.line(
			"cloudflare_stats",
			base,
			[]pair{
				numeric("bytes", sum, "bytes"),
				numeric("cachedBytes", sum, "cachedBytes"),
				numeric("cachedRequests", sum, "cachedRequests"),
				numeric("encryptedBytes", sum, "encryptedBytes"),
				numeric("encryptedRequests", sum, "encryptedRequests"),
				numeric("pageViews", sum, "pageViews"),
				numeric("requests", sum, "requests"),
				numeric("threats", sum, "threats"),
				numeric("uniqueVisitors", object(row["uniq"]), "uniques"),
			},
			ts,
		)
	}
}

func (e *exporter) collectAICrawl(z zone, datetimeStart, datetimeEnd string) {
	zd := zoneData(
		e.gql(
			aiCrawlQuery,
			map[string]string{"zoneTag": z.ID, "start": datetimeStart, "end": datetimeEnd},
		),
	)
	for _, r := range array(zd["httpRequestsAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_ai_crawl",
			tags(
				"zone",
				z.Domain,
				"crawler",
				stringAt(d, "userAgent"),
				"host",
				stringAt(d, "clientRequestHTTPHost"),
			),
			[]pair{
				numeric("requests", o, "count"),
				numeric("edgeResponseBytes", o, "sum", "edgeResponseBytes"),
			},
			unix(stringAt(d, "datetimeHour")),
		)
	}
}

func (e *exporter) collectWorkers(datetimeStart, datetimeEnd string) {
	a := account(
		e.gql(
			workersQuery,
			map[string]string{
				"accountTag": e.config.CloudflareAccountTag,
				"start":      datetimeStart,
				"end":        datetimeEnd,
			},
		),
	)
	for _, spec := range []struct {
		name, dataset, tagName string
		strings                []string
		nums                   [][]string
	}{
		{
			"cloudflare_stats_workers", "workersInvocationsAdaptive", "worker",
			[]string{"status"},
			[][]string{
				{"quantiles", "cpuTimeP50"},
				{"quantiles", "cpuTimeP99"},
				{"quantiles", "durationP50"},
				{"quantiles", "durationP99"},
				{"quantiles", "responseBodySizeP50"},
				{"quantiles", "responseBodySizeP99"},
				{"quantiles", "wallTimeP50"},
				{"quantiles", "wallTimeP99"},
				{"sum", "clientDisconnects"},
				{"sum", "cpuTimeUs"},
				{"sum", "duration"},
				{"sum", "errors"},
				{"sum", "requests"},
				{"sum", "responseBodySize"},
				{"sum", "subrequests"},
				{"sum", "wallTime"},
			},
		},
		{
			"cloudflare_stats_pf", "pagesFunctionsInvocationsAdaptiveGroups", "scriptName",
			[]string{"status", "usageModel"},
			[][]string{
				{"quantiles", "cpuTimeP50"},
				{"quantiles", "cpuTimeP99"},
				{"quantiles", "durationP50"},
				{"quantiles", "durationP99"},
				{"sum", "clientDisconnects"},
				{"sum", "duration"},
				{"sum", "errors"},
				{"sum", "requests"},
				{"sum", "responseBodySize"},
				{"sum", "subrequests"},
				{"sum", "wallTime"},
			},
		},
	} {
		for _, r := range array(a[spec.dataset]) {
			o := object(r)
			d := object(o["dimensions"])
			fs := []pair{}
			for _, k := range spec.strings {
				value := stringAt(d, k)
				escapedValue := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\\n`, "\r", `\\r`).Replace(value)
				fs = append(fs, pair{k, `"` + escapedValue + `"`, false})
			}
			for _, p := range spec.nums {
				fs = append(fs, numeric(p[len(p)-1], o, p...))
			}
			e.line(
				spec.name,
				tags(
					"account",
					e.config.CloudflareAccountTag,
					spec.tagName,
					stringAt(d, "scriptName"),
				),
				fs,
				unix(stringAt(d, "datetimeHour")),
			)
		}
	}
}

func (e *exporter) collectKV(oneHourAgo, twoHoursAgo, now string) {
	var wg sync.WaitGroup
	for _, id := range e.namespaces() {
		wg.Go(func() {
			a := account(
				e.gql(
					kvQuery,
					map[string]string{
						"accountTag":  e.config.CloudflareAccountTag,
						"namespaceId": id,
						"one":         oneHourAgo,
						"two":         twoHoursAgo,
						"end":         now,
					},
				),
			)
			for _, r := range array(a["kvOperationsAdaptiveGroups"]) {
				o := object(r)
				d := object(o["dimensions"])
				actionType := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\\n`, "\r", `\\r`).
					Replace(stringAt(d, "actionType"))
				result := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\\n`, "\r", `\\r`).
					Replace(stringAt(d, "result"))
				e.line(
					"cloudflare_stats_kv_ops",
					tags(
						"account",
						e.config.CloudflareAccountTag,
						"namespace",
						stringAt(d, "namespaceId"),
					),
					[]pair{
						{"actionType", `"` + actionType + `"`, false},
						{"result", `"` + result + `"`, false},
						numeric("responseStatusCode", d, "responseStatusCode"),
						numeric("latencyMsP50", o, "quantiles", "latencyMsP50"),
						numeric("latencyMsP99", o, "quantiles", "latencyMsP99"),
						numeric("objectBytes", o, "sum", "objectBytes"),
						numeric("requests", o, "sum", "requests"),
					},
					unix(stringAt(d, "datetimeHour")),
				)
			}
			for _, r := range array(a["kvStorageAdaptiveGroups"]) {
				o := object(r)
				d := object(o["dimensions"])
				e.line(
					"cloudflare_stats_kv_storage",
					tags(
						"account",
						e.config.CloudflareAccountTag,
						"namespace",
						stringAt(d, "namespaceId"),
					),
					[]pair{
						numeric("byteCount", o, "max", "byteCount"),
						numeric("keyCount", o, "max", "keyCount"),
					},
					unix(stringAt(d, "datetimeHour")),
				)
			}
		})
	}
	wg.Wait()
}

func (e *exporter) collectBillable() {
	var rows []json.RawMessage
	e.rest(
		fmt.Sprintf(
			"%s/accounts/%s/billable-usage",
			cloudflareAPI,
			url.PathEscape(e.config.CloudflareAccountTag),
		),
		&rows,
	)
	for _, r := range rows {
		o := object(r)
		pick := func(a, b string) string {
			if v := stringAt(o, a); v != "" {
				return v
			}
			return stringAt(o, b)
		}
		fs := []pair{}
		for _, k := range []string{"ConsumedQuantity", "PricingQuantity", "ContractedCost", "BilledCost", "EffectiveCost", "CumulatedPricingQuantity", "CumulatedContractedCost"} {
			value := o[k]
			if len(value) == 0 || string(value) == "null" {
				continue
			}
			var number json.Number
			if err := json.Unmarshal(value, &number); err != nil {
				continue
			}
			if _, err := strconv.ParseFloat(number.String(), 64); err != nil {
				continue
			}
			fs = append(fs, pair{strings.ToLower(k[:1]) + k[1:], number.String(), false})
		} // Preserve lower-camel Influx names.
		if len(fs) == 0 {
			continue
		}
		tt := tags("account", e.config.CloudflareAccountTag)
		tt = append(tt, []pair{
			{"billingCurrency", stringAt(o, "BillingCurrency"), true},
			{"service", pick("ServiceName", "x_BillableMetricName"), true},
			{"serviceFamily", pick("ServiceFamilyName", "x_ProductFamilyName"), true},
			{"consumedUnit", stringAt(o, "ConsumedUnit"), true},
			{"zoneId", pick("ZoneId", "x_ZoneId"), true},
			{"zone", pick("ZoneName", "x_ZoneName"), true},
		}...)
		e.line("cloudflare_billable_usage", tt, fs, unix(stringAt(o, "ChargePeriodStart")))
	}
}

func (e *exporter) collectD1(date, datetimeStart, datetimeEnd string) {
	a := account(
		e.gql(
			d1Query,
			map[string]string{
				"accountTag": e.config.CloudflareAccountTag,
				"date":       date,
				"start":      datetimeStart,
				"end":        datetimeEnd,
			},
		),
	)
	for _, r := range array(a["d1AnalyticsAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_d1",
			tags("account", e.config.CloudflareAccountTag, "database", stringAt(d, "databaseId")),
			[]pair{
				numeric("readQueries", o, "sum", "readQueries"),
				numeric("writeQueries", o, "sum", "writeQueries"),
				numeric("rowsRead", o, "sum", "rowsRead"),
				numeric("rowsWritten", o, "sum", "rowsWritten"),
				numeric("queryBatchResponseBytes", o, "sum", "queryBatchResponseBytes"),
				numeric("queryBatchTimeMs", o, "avg", "queryBatchTimeMs"),
				numeric("queryBatchTimeMsP90", o, "quantiles", "queryBatchTimeMsP90"),
			},
			unix(stringAt(d, "date")),
		)
	}
	for _, r := range array(a["d1StorageAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_d1_storage",
			tags("account", e.config.CloudflareAccountTag, "database", stringAt(d, "databaseId")),
			[]pair{numeric("databaseSizeBytes", o, "max", "databaseSizeBytes")},
			unix(stringAt(d, "date")),
		)
	}
	for _, r := range array(a["d1QueriesAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_d1_queries",
			tags(
				"account",
				e.config.CloudflareAccountTag,
				"database",
				stringAt(d, "databaseId"),
				"region",
				stringAt(d, "servedByRegion"),
				"role",
				stringAt(d, "databaseRole"),
			),
			[]pair{
				numeric("queries", o, "count"),
				numeric("rowsRead", o, "sum", "rowsRead"),
				numeric("rowsWritten", o, "sum", "rowsWritten"),
				numeric("queryDurationMsP50", o, "quantiles", "queryDurationMsP50"),
				numeric("queryDurationMsP95", o, "quantiles", "queryDurationMsP95"),
				numeric("queryDurationMsP99", o, "quantiles", "queryDurationMsP99"),
			},
			unix(stringAt(d, "datetimeFiveMinutes")),
		)
	}
}

func (e *exporter) collectR2(datetimeStart, datetimeEnd string) {
	a := account(
		e.gql(
			r2Query,
			map[string]string{
				"accountTag": e.config.CloudflareAccountTag,
				"start":      datetimeStart,
				"end":        datetimeEnd,
			},
		),
	)
	for _, r := range array(a["r2OperationsAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_r2_operations",
			tags(
				"account",
				e.config.CloudflareAccountTag,
				"bucket",
				stringAt(d, "bucketName"),
				"storageClass",
				stringAt(d, "storageClass"),
				"actionType",
				stringAt(d, "actionType"),
				"actionStatus",
				stringAt(d, "actionStatus"),
				"responseStatusCode",
				stringAt(d, "responseStatusCode"),
			),
			[]pair{
				numeric("requests", o, "sum", "requests"),
				numeric("responseBytes", o, "sum", "responseBytes"),
			},
			unix(stringAt(d, "datetime")),
		)
	}
	for _, r := range array(a["r2StorageAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_r2_storage",
			tags(
				"account",
				e.config.CloudflareAccountTag,
				"bucket",
				stringAt(d, "bucketName"),
				"storageClass",
				stringAt(d, "storageClass"),
			),
			[]pair{
				numeric("objectCount", o, "max", "objectCount"),
				numeric("uploadCount", o, "max", "uploadCount"),
				numeric("payloadSize", o, "max", "payloadSize"),
				numeric("metadataSize", o, "max", "metadataSize"),
			},
			unix(stringAt(d, "datetime")),
		)
	}
}

func (e *exporter) collectEmail(z zone, datetimeStart, datetimeEnd string) {
	zd := zoneData(
		e.gql(
			emailQuery,
			map[string]string{"zoneTag": z.ID, "start": datetimeStart, "end": datetimeEnd},
		),
	)
	for _, r := range array(zd["emailSendingAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_email_sending",
			tags(
				"zone",
				z.Domain,
				"status",
				stringAt(d, "status"),
				"eventType",
				stringAt(d, "eventType"),
				"sendingDomain",
				stringAt(d, "sendingDomain"),
			),
			[]pair{numeric("emails", o, "count")},
			unix(stringAt(d, "datetimeHour")),
		)
	}
	for _, r := range array(zd["emailRoutingAdaptiveGroups"]) {
		o := object(r)
		d := object(o["dimensions"])
		e.line(
			"cloudflare_stats_email_routing",
			tags(
				"zone",
				z.Domain,
				"status",
				stringAt(d, "status"),
				"eventType",
				stringAt(d, "eventType"),
				"action",
				stringAt(d, "action"),
				"ruleMatched",
				stringAt(d, "ruleMatched"),
			),
			[]pair{numeric("emails", o, "count")},
			unix(stringAt(d, "datetimeHour")),
		)
	}
}

func (e *exporter) upload() {
	e.payloadMu.Lock()
	payload := append([]byte(nil), e.payload.Bytes()...)
	e.payloadMu.Unlock()
	if len(payload) == 0 {
		log.Fatalln("no data to send")
	}
	var zipped bytes.Buffer
	zw := gzip.NewWriter(&zipped)
	if _, err := zw.Write(payload); err != nil {
		log.Fatalf("compressing data: %v", err)
	}
	if err := zw.Close(); err != nil {
		log.Fatalf("compressing data: %v", err)
	}
	u := fmt.Sprintf(
		"https://%s/api/v2/write?precision=s&org=%s&bucket=%s",
		e.config.InfluxDBHost,
		url.QueryEscape(e.config.Org),
		url.QueryEscape(e.config.Bucket),
	)
	req, err := http.NewRequest(http.MethodPost, u, &zipped)
	if err != nil {
		log.Fatalf("creating InfluxDB request: %v", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Token "+e.config.InfluxDBApiToken)
	req.Header.Set("Content-Encoding", "gzip")
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	resp, err := e.client.Do(req)
	if err != nil {
		log.Fatalf("sending data: %v", err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.Printf("closing InfluxDB response body: %v", err)
		}
	}()
	statusOK := resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("reading InfluxDB response: %v", err)
	}
	if !statusOK {
		log.Fatalf("InfluxDB write failed: %s: %s", resp.Status, body)
	}
}

func main() {
	c := loadConfig()
	transport := &retryableTransport{
		transport:             &http.Transport{},
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}
	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
	}
	e := &exporter{config: c, client: client, now: time.Now().UTC()}
	now := e.now.Format(time.RFC3339)
	oneHourAgo := e.now.Add(-time.Hour).Format(time.RFC3339)
	twoHoursAgo := e.now.Add(-2 * time.Hour).Format(time.RFC3339)
	date := e.now.Format("2006-01-02")

	var zones []zone
	var wg sync.WaitGroup
	wg.Go(func() { zones = e.zones() })
	wg.Wait()

	wg.Go(func() { e.collectQueues(twoHoursAgo, now) })
	wg.Go(func() { e.collectWorkers(oneHourAgo, now) })
	wg.Go(func() { e.collectKV(oneHourAgo, twoHoursAgo, now) })
	wg.Go(e.collectBillable)
	wg.Go(func() { e.collectD1(date, twoHoursAgo, now) })
	wg.Go(func() { e.collectR2(twoHoursAgo, now) })
	for _, zone := range zones {
		zone := zone
		wg.Go(func() { e.collectZoneHourly(zone, date) })
		wg.Go(func() { e.collectAICrawl(zone, twoHoursAgo, now) })
		wg.Go(func() { e.collectEmail(zone, twoHoursAgo, now) })
	}
	wg.Wait()

	wg.Go(e.upload)
	wg.Wait()
}
