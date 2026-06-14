#!/usr/bin/env bashio

# The script assumes that basic authentication is configured
#
# DASHBOARDS_DIRECTORY represents the path to the directory
# where the JSON files corresponding to the dashboards exist.
# The default location is relative to the execution of the
# script.
#
# Source: https://github.com/cirocosta/sample-grafana/blob/master/update-dashboards.sh

set -o errexit

HOST=$(bashio::config 'grafana_host')
PORT=$(bashio::config 'grafana_port')
USER=$(bashio::config 'grafana_user')
PASS=$(bashio::config 'grafana_pass')
DASHBOARDS_DIRECTORY="/dashboards"
FOLDER_NAME=$(bashio::config 'grafana_folder_name')

readonly HOST PORT USER PASS DASHBOARDS_DIRECTORY FOLDER_NAME


main() {
  local task=$1

  URL="http://$HOST:$PORT"
  LOGIN="$USER:$PASS"

  # Support Bearer token auth via GRAFANA_TOKEN env var (takes precedence over user/pass)
  if [[ -n "${GRAFANA_TOKEN:-}" ]]; then
    AUTH_HEADER="Authorization: Bearer $GRAFANA_TOKEN"
  else
    AUTH_HEADER=""
  fi

  case $task in
      backup) backup;;
      restore) restore;;
      *)     exit 1;;
  esac
}

_curl() {
  if [[ -n "$AUTH_HEADER" ]]; then
    curl --silent --show-error -H "$AUTH_HEADER" "$@"
  else
    curl --silent --show-error --user "$LOGIN" "$@"
  fi
}

backup() {
  local dashboard_json

  for dashboard in $(list_dashboards); do
    dashboard_json=$(get_dashboard "$dashboard")

    if [[ -z "$dashboard_json" ]]; then
      echo "ERROR: Couldn't retrieve dashboard $dashboard."
      exit 1
    fi

    echo "$dashboard_json" > "$DASHBOARDS_DIRECTORY/$dashboard".json

    echo "BACKED UP $(basename "$dashboard").json"
  done
}


restore() {
  bashio::log.info "Checking for Grafana datasource: TeslaMate"
  datasources=$(_curl -H "Content-Type: application/json" "$URL/api/datasources")

  if [[ $datasources == *"statusCode"* ]]; then
    bashio::log.error "Error getting Grafana datasources: $(echo "$datasources" | jq -r .message)"
    bashio::log.debug "$datasources"
    exit 1
  fi

  DS=$(echo "$datasources" | jq ".[] | select(.name==\"TeslaMate\")")

  if [[ -z "$DS" ]]; then
    bashio::log.info "TeslaMate datasource not found, creating it..."
    DS_PAYLOAD="{\"name\":\"TeslaMate\",\"type\":\"postgres\",\"access\":\"proxy\",\"url\":\"${DATABASE_HOST}:${DATABASE_PORT}\",\"user\":\"${DATABASE_USER}\",\"secureJsonData\":{\"password\":\"${DATABASE_PASS}\"},\"jsonData\":{\"database\":\"${DATABASE_NAME}\",\"sslmode\":\"disable\",\"maxOpenConns\":0,\"maxIdleConns\":2,\"connMaxLifetime\":14400,\"postgresVersion\":1500,\"timescaledb\":false}}"
    create_result=$(_curl -X POST -H "Content-Type: application/json" \
      -d "$DS_PAYLOAD" \
      "$URL/api/datasources")
    if echo "$create_result" | jq -e '.id' > /dev/null 2>&1; then
      bashio::log.info "TeslaMate datasource created successfully"
      DS="$create_result"
    else
      bashio::log.error "Failed to create TeslaMate datasource: $create_result"
      exit 1
    fi
  fi

  bashio::log.info "Checking for Grafana folder: $FOLDER_NAME"
  folders=$(_curl -H "Content-Type: application/json" "$URL/api/folders")

  if [[ $folders == *"statusCode"* ]]; then
    bashio::log.error "Error getting Grafana folders: $(echo "$folders" | jq -r .message)"
    bashio::log.debug "$folders"
    exit 1
  fi

  FLD=$(echo "$folders" | jq ".[] | select(.title==\"$FOLDER_NAME\")")

  if [[ -z "$FLD" ]]; then
    bashio::log.info "Not found... creating"
    FLD=$(_curl \
          -X POST -H "Content-Type: application/json" \
          -d "{\"title\":\"$FOLDER_NAME\"}" \
          "$URL/api/folders")
  fi

  FOLDER_ID=$(echo "$FLD" | jq -r .id)

  if [[ -z "$FOLDER_ID" ]]; then
    bashio::log.error "Could not determine Grafana folder id"
    exit 1
  fi

  find "$DASHBOARDS_DIRECTORY" -type f -name \*.json -print0 |
      while IFS= read -r -d '' dashboard; do
          _curl \
            --output /dev/null \
            -X POST -H "Content-Type: application/json" \
            -d "{\"dashboard\":$(cat "$dashboard"),\"overwrite\":true,\"folderId\":$FOLDER_ID, \
                    \"inputs\":[{\"name\":\"DS_POSTGRES\",\"type\":\"datasource\", \
                    \"pluginId\":\"postgres\",\"value\":\"TeslaMate\"}]}" \
            "$URL/api/dashboards/import"

        bashio::log.info "... RESTORED $(basename "$dashboard")"
      done
  bashio::log.info "Finished Importing Grafana Dashboards"
}


get_dashboard() {
  local dashboard=$1

  if [[ -z "$dashboard" ]]; then
    echo "ERROR:
  A dashboard must be specified.
  "
    exit 1
  fi

  _curl "$URL/api/dashboards/db/$dashboard" |
    jq '.dashboard | .id = null'
}


list_dashboards() {
  _curl "$URL/api/search" |
    jq -r '.[] | select(.type == "dash-db") | .uri' |
    cut -d '/' -f2
}

main "$@"
