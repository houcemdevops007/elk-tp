#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verif-k8s.sh — points de contrôle de la collecte Kubernetes ({{STUDENT_ID}})
#  Usage :  ES_API_KEY='<cle>' ./verif-k8s.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES_URL="{{ES_URL}}"
CA_PATH="{{CA_PATH}}"
NS="{{NAMESPACE}}"
CLE_GENEREE='{{ES_API_KEY}}'
CLE="${ES_API_KEY:-$CLE_GENEREE}"
export KUBECONFIG="{{KUBECONFIG}}"

es() { curl -sS --cacert "$CA_PATH" -H "Authorization: ApiKey ${CLE}" "$@"; }

echo "═══ 1. LA SOURCE PRODUIT-ELLE ? ═══"
kubectl -n "$NS" get pods -o wide
echo "--- logs vus par kubectl (la vue COURT TERME) ---"
kubectl -n "$NS" logs -l app.kubernetes.io/name=shopflow-worker --tail=3 --prefix 2>/dev/null
echo "--- fichiers correspondants sur le nœud ---"
sudo ls -l /var/log/containers/ 2>/dev/null | grep "$NS" | head -3

echo
echo "═══ 2. L'AGENT EST-IL SAIN ? ═══"
kubectl -n elastic-agent get ds elastic-agent \
  -o custom-columns='SOUHAITES:.status.desiredNumberScheduled,PRETS:.status.numberReady'
kubectl -n elastic-agent get pods -o wide
echo "--- erreurs récentes de l'agent ---"
kubectl -n elastic-agent logs ds/elastic-agent --tail=200 2>/dev/null \
  | grep -i -m5 'error\|fail' || echo "  aucune erreur récente (bon signe)"

echo
echo "═══ 3. kube-state-metrics répond-il ? ═══"
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics
POD="$(kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$POD" ]; then
  kubectl -n kube-system exec "$POD" -- wget -qO- 127.0.0.1:8080/metrics 2>/dev/null \
    | grep -c '^kube_' | sed 's/^/  séries exposées : /' \
    || echo "  (exec indisponible : vérifiez depuis le Service)"
fi

echo
echo "═══ 4. ELASTICSEARCH A-T-IL REÇU ? ═══"
for DS in "logs-kubernetes.container_logs-${NS}" \
          "metrics-kubernetes.container-${NS}" \
          "metrics-kubernetes.pod-${NS}" \
          "metrics-kubernetes.state_container-${NS}" \
          "metrics-kubernetes.state_pod-${NS}" \
          "metrics-kubernetes.node-${NS}" \
          "metrics-kubernetes.event-${NS}"; do
  N=$(es "${ES_URL}/${DS}/_count" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","absent"))' 2>/dev/null || echo "absent")
  printf "  %-50s %s\n" "$DS" "$N"
done

echo
echo "--- les métadonnées sont-elles bien là ? (sinon : RBAC de l'agent) ---"
es "${ES_URL}/logs-kubernetes.container_logs-${NS}/_search?size=1&sort=@timestamp:desc" \
  | python3 -c '
import json,sys
h = json.load(sys.stdin).get("hits", {}).get("hits", [])
if not h:
    print("  aucun document"); raise SystemExit
k = h[0]["_source"].get("kubernetes", {})
for champ in ("namespace", "node", "pod", "container", "deployment", "labels"):
    print(f"  kubernetes.{champ:<12}:", k.get(champ))
print("  log.level             :", h[0]["_source"].get("log", {}).get("level"))
print("  message               :", str(h[0]["_source"].get("message"))[:80])
'

echo
echo "--- TABLEAU DE DIAGNOSTIC : état réel de vos pods, vu par Elastic ---"
es -H 'Content-Type: application/json' \
  "${ES_URL}/metrics-kubernetes.state_container-${NS}/_search?size=0" -d '{
  "query": { "range": { "@timestamp": { "gte": "now-15m" } } },
  "aggs": { "par_pod": { "terms": { "field": "kubernetes.pod.name", "size": 20 },
    "aggs": {
      "restarts": { "max": { "field": "kubernetes.container.status.restarts" } },
      "raison":   { "terms": { "field": "kubernetes.container.status.last_terminated_reason", "size": 1 } }
    } } } }' \
  | python3 -c '
import json, sys
a = json.load(sys.stdin).get("aggregations", {}).get("par_pod", {}).get("buckets", [])
if not a:
    print("  (aucune metrique state_container : kube-state-metrics est-il collecte ?)")
print("  %-44s %12s  %s" % ("pod", "redemarrages", "raison du dernier arret"))
for b in a:
    r = b["raison"]["buckets"]
    print("  %-44s %12d  %s" % (b["key"][:44],
                                int(b["restarts"]["value"] or 0),
                                r[0]["key"] if r else "-"))
'
echo
echo "═══ Terminé ═══"
