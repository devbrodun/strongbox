#!/usr/bin/env bash
# lib/http.sh — HTTP request routing and response helpers
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# Public API:
#   http_serve <bind_addr> <port>       -> blocking HTTP server loop (netcat/socat based)
#   http_respond <status_code> <body>   -> writes HTTP response to stdout (used inside handlers)
#   http_parse_request                  -> parses stdin into _HTTP_METHOD, _HTTP_PATH,
#                                          _HTTP_QUERY, _HTTP_HEADERS, _HTTP_BODY, _HTTP_TOKEN
#
# Routing table (all routes, dispatch to handler functions defined in bin/strongbox):
#
#   SEALED state: only /v1/sys/health and /v1/sys/unseal respond; all else -> 503
#
#   POST   /v1/sys/init                    -> handle_sys_init
#   POST   /v1/sys/unseal                  -> handle_sys_unseal
#   POST   /v1/sys/seal                    -> handle_sys_seal
#   GET    /v1/sys/health                  -> handle_sys_health
#
#   PUT    /v1/secrets/{path}              -> handle_secret_write
#   GET    /v1/secrets/{path}              -> handle_secret_read
#   DELETE /v1/secrets/{path}              -> handle_secret_delete
#
#   GET    /v1/dynamic-postgres/{role}     -> handle_dynamic_postgres_read
#
#   POST   /v1/auth/login                  -> handle_auth_login
#   POST   /v1/auth/revoke                 -> handle_auth_revoke
#   GET    /v1/auth/self                   -> handle_auth_self
#
#   PUT    /v1/policies/{name}             -> handle_policy_write
#   GET    /v1/policies/{name}             -> handle_policy_read
#
#   POST   /v1/leases/{id}/renew           -> handle_lease_renew
#   POST   /v1/leases/{id}/revoke          -> handle_lease_revoke
#
#   GET    /v1/audit                       -> handle_audit_query
#
#   POST   /v1/internal/vote               -> consensus_handle_vote_request  (peer-to-peer)
#   POST   /v1/internal/heartbeat          -> consensus_handle_heartbeat      (peer-to-peer)

set -euo pipefail

_HTTP_METHOD=""
_HTTP_PATH=""
_HTTP_QUERY=""
_HTTP_BODY=""
_HTTP_TOKEN=""

# TODO: implement http_serve    (socat or netcat loop; one process per connection)
# TODO: implement http_respond  (print "HTTP/1.1 <code> ...\r\nContent-Type: application/json\r\n\r\n<body>")
# TODO: implement http_parse_request  (read method/path/headers/body from stdin)
# TODO: implement _http_route   (match method+path to handler; enforce sealed check)
# TODO: implement _http_extract_token  (parse "Authorization: Bearer <token>" header)
# TODO: implement _http_extract_query_param <name>  -> value or empty string

http_serve()   { echo "NOT_IMPLEMENTED" >&2; return 1; }
http_respond() { echo "NOT_IMPLEMENTED" >&2; return 1; }
