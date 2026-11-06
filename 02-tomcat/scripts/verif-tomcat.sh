#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verif-tomcat.sh — les quatre points de contrôle, côté Tomcat ({{STUDENT_ID}})
#  Usage :  ES_API_KEY='<cle>' ./verif-tomcat.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES_URL="{{ES_URL}}"
CA_PATH="{{CA_PATH}}"
NS="{{NAMESPACE}}"
LOGS="{{CATALINA_LOGS}}"
PORT="{{TOMCAT_PORT}}"
CTX="{{APP_CONTEXT}}"
CLE_GENEREE='{{ES_API_KEY}}'
CLE="${ES_API_KEY:-$CLE_GENEREE}"

es() { curl -sS --cacert "$CA_PATH" -H "Authorization: ApiKey ${CLE}" "$@"; }

echo "═══ 1. LA SOURCE PRODUIT-ELLE ? ═══"
echo "--- l'application répond ---"
curl -s "http://localhost:${PORT}/${CTX}/health" ; echo
echo "--- journal d'accès (le dernier champ avant le thread est %D, en MILLISECONDES) ---"
sudo tail -2 "${LOGS}"/localhost_access_log.*.txt 2>/dev/null | tail -2
echo "--- catalina.out : les lignes JSON de l'application ---"
sudo grep -h '"service.name":"shopflow-api"' "${LOGS}/catalina.out" 2>/dev/null | tail -2
echo "--- dernier déploiement enregistré ---"
sudo grep -h 'Deployment of web application' "${LOGS}"/catalina.*.log "${LOGS}/catalina.out" 2>/dev/null | tail -2

echo
echo "═══ 2. LA JVM EST-ELLE OBSERVABLE ? ═══"
PID="$(pgrep -f 'catalina' | head -1 || true)"
if [ -n "$PID" ]; then
  echo "PID Tomcat : $PID"
  sudo -u "{{TOMCAT_USER}}" jcmd "$PID" VM.flags 2>/dev/null | tr ' ' '\n' \
    | grep -E 'MaxHeapSize|InitialHeapSize|UseG1GC|HeapDump' || echo "  (jcmd indisponible)"
  echo "--- occupation des zones et compteurs de GC (jstat) ---"
  sudo -u "{{TOMCAT_USER}}" jstat -gcutil "$PID" 1000 3 2>/dev/null || echo "  (jstat indisponible)"
  echo "--- Jolokia : expose-t-il les MBeans ? ---"
  curl -s "http://127.0.0.1:{{JOLOKIA_PORT}}/jolokia/read/java.lang:type=Memory/HeapMemoryUsage" \
    | head -c 300 ; echo
else
  echo "[!] aucun processus Tomcat trouvé : sudo systemctl status tomcat"
fi

echo
echo "═══ 3. L'AGENT LIT-IL ? ═══"
sudo elastic-agent status --output=full | grep -iA3 'tomcat\|filestream\|jolokia' | head -40
sudo elastic-agent inspect | grep -A4 -i 'paths' | grep -i tomcat | head

echo
echo "═══ 4. ELASTICSEARCH A-T-IL REÇU ? ═══"
for DS in "logs-shopflow_tomcat.access-${NS}" "logs-shopflow_tomcat.catalina-${NS}" \
          "logs-shopflow_tomcat.app-${NS}" "metrics-jolokia.jvm-${NS}"; do
  N=$(es "${ES_URL}/${DS}/_count" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","absent"))' 2>/dev/null || echo "absent")
  printf "  %-46s %s document(s)\n" "$DS" "$N"
done

echo
echo "--- CONTRÔLE D'UNITÉ : la plus longue durée vue par Elastic ---"
#  À comparer avec la valeur mesurée par curl : si Elastic affiche 1 000 fois
#  moins, le facteur de conversion ms -> ns est faux dans le pipeline.
es -H 'Content-Type: application/json' \
  "${ES_URL}/logs-shopflow_tomcat.access-${NS}/_search?size=0" -d '{
    "aggs": { "duree_max_ns": { "max": { "field": "event.duration" } } } }' \
  | python3 -c '
import json,sys
v = json.load(sys.stdin).get("aggregations", {}).get("duree_max_ns", {}).get("value")
print("  max event.duration :", v, "ns" if v else "(aucune donnée)")
if v: print("  soit               :", round(v/1e9, 3), "s")
'
echo "--- mesure de référence côté client, pour comparaison ---"
curl -s -o /dev/null -w "  curl sur /api/lent?ms=1500 : %{time_total}s\n" \
  "http://localhost:${PORT}/${CTX}/api/lent?ms=1500"

echo
echo "--- CONTRÔLE QUALITÉ : documents mal parsés (DOIT valoir 0) ---"
es -H 'Content-Type: application/json' \
  "${ES_URL}/logs-shopflow_tomcat.*-${NS}/_count" -d '{
    "query": { "bool": { "should": [
      { "exists": { "field": "error.message" } },
      { "terms": { "tags": ["grok_tomcat_failed", "grok_tomcat_access_failed"] } }
    ], "minimum_should_match": 1 } } }'
echo
echo "═══ Terminé ═══"
