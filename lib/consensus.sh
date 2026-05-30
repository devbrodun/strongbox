#!/usr/bin/env bash
# lib/consensus.sh — Hand-rolled leader election (Raft-inspired)
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# Public API:
#   consensus_start                -> launches election + heartbeat loops (non-blocking)
#   consensus_is_leader            -> exit 0 if this node is current leader
#   consensus_leader_addr          -> prints "host:port" of current leader
#   consensus_current_term         -> prints current term integer
#   consensus_handle_vote_request  <body_json>  -> prints JSON response
#   consensus_handle_heartbeat     <body_json>  -> exit 0
#
# Rules:
#   - Each node has a term number, vote record, and role (follower/candidate/leader)
#   - Election timeout: random 150-300ms; on timeout, node increments term, votes for self, requests votes
#   - Leader sends heartbeats every 50ms; resets follower timeout
#   - A node votes for at most one candidate per term
#   - Writes accepted by leader only; followers return 307 with leader hint
#   - Reads may be served from followers (document staleness in README)
#   - Minority partition (< quorum) refuses writes
#   - NO external raft/etcd libraries — implement yourself

set -euo pipefail

_CONSENSUS_ROLE="follower"      # follower | candidate | leader
_CONSENSUS_TERM=0
_CONSENSUS_LEADER=""
_CONSENSUS_VOTED_FOR=""
_CONSENSUS_VOTES=0

STRONGBOX_PEERS="${STRONGBOX_PEERS:-}"   # comma-separated "host:port,host:port"
STRONGBOX_NODE_ADDR="${STRONGBOX_NODE_ADDR:-localhost:8200}"

# TODO: implement consensus_start           (spawns _consensus_election_loop & _consensus_heartbeat_loop)
# TODO: implement _consensus_election_loop  (random timeout, request votes, tally)
# TODO: implement _consensus_heartbeat_loop (leader only: broadcast heartbeat to peers)
# TODO: implement consensus_is_leader
# TODO: implement consensus_leader_addr
# TODO: implement consensus_current_term
# TODO: implement consensus_handle_vote_request  (grant vote if term >= current and not yet voted)
# TODO: implement consensus_handle_heartbeat     (reset election timeout, update leader/term)
# TODO: implement _consensus_request_vote <peer>
# TODO: implement _consensus_quorum              -> ceil((peers+1)/2)

consensus_start()               { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_is_leader()           { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_leader_addr()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_current_term()        { echo "0"; }
consensus_handle_vote_request() { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_handle_heartbeat()    { echo "NOT_IMPLEMENTED" >&2; return 1; }
