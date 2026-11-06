#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verif-ingestion.sh — les quatre points de contrôle, pour {{STUDENT_ID}}
#
#  Méthode : on remonte la chaîne de la source vers l'affichage et on
#  S'ARRÊTE AU PREMIER point qui échoue. « Ça ne marche pas » n'est pas un
#  diagnostic ; « le point 3 échoue avec une erreur de certificat » en est un.
#
#  Usage :  ES_API_KEY='<votre-cle>' ./verif-ingestion.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES_URL="{{ES_URL}}"
CA_PATH="{{CA_PATH}}"
NS="{{NAMESPACE}}"
HOTE="{{STUDENT_HOST}}"
# La clé d'API se passe de préférence par la variable d'environnement.
# Le générateur peut aussi l'inscrire ici : dans ce cas, protégez le fichier
# (chmod 600) et ne le versionnez jamais.
CLE_GENEREE='{{ES_API_KEY}}'
CLE="${ES_API_KEY:-$CLE_GENEREE}"

if [ -z "$CLE" ]; then
  echo "[ERREUR] clé d'API absente : ES_API_KEY='<cle>' $0" >&2
  exit 1
fi

es() { curl -sS --cacert "$CA_PATH" -H "Authorization: ApiKey ${CLE}" "$@"; }

echo "═══ 1. LA SOURCE PRODUIT-ELLE ? ═══"
sudo tail -2 {{APACHE_LOG_DIR}}/access.log      || echo "  [!] access.log illisible ou absent"
sudo tail -1 {{APACHE_LOG_DIR}}/access_json.log | python3 -m json.tool \
  || echo "  [!] access_json.log absent ou JSON invalide -> revoir shopflow-logs.conf"
curl -s "http://localhost/server-status?auto" | head -9 \
  || echo "  [!] mod_status injoignable -> revoir server-status.conf"

echo
echo "═══ 2. L'AGENT LIT-IL LA BONNE CHOSE ? ═══"
sudo elastic-agent status --output=full | sed -n '1,40p'
echo "--- chemins réellement surveillés (config reçue de Fleet) ---"
sudo elastic-agent inspect | grep -A4 -i 'paths' | head -30

echo
echo "═══ 3. L'AGENT ENVOIE-T-IL ? ═══"
sudo grep -h '"log.level":"error"' \
  /opt/Elastic/Agent/data/elastic-agent-*/logs/*.ndjson 2>/dev/null | tail -5 \
  || echo "  aucune erreur récente dans les logs de l'agent (bon signe)"

echo
echo "═══ 4. ELASTICSEARCH A-T-IL REÇU ? ═══"
for DS in "logs-apache.access-${NS}" "logs-apache.error-${NS}" \
          "logs-shopflow_apache.access_json-${NS}" "metrics-apache.status-${NS}"; do
  N=$(es "${ES_URL}/${DS}/_count" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","?"))' 2>/dev/null || echo "absent")
  printf "  %-46s %s document(s)\n" "$DS" "$N"
done

echo
echo "--- fraîcheur : dernier document du journal JSON ---"
es "${ES_URL}/logs-shopflow_apache.access_json-${NS}/_search?size=1&sort=@timestamp:desc" \
  | python3 -c '
import json,sys
d = json.load(sys.stdin)
h = d.get("hits", {}).get("hits", [])
if not h:
    print("  aucun document : élargissez la fenêtre ou vérifiez le namespace"); raise SystemExit
s = h[0]["_source"]
print("  @timestamp      :", s.get("@timestamp"))
print("  url.path        :", s.get("url", {}).get("path"))
print("  status_code     :", s.get("http", {}).get("response", {}).get("status_code"))
print("  event.duration  :", s.get("event", {}).get("duration"), "ns")
print("  status_class    :", s.get("shopflow", {}).get("status_class"))
print("  host.name       :", s.get("host", {}).get("name"))
'

echo
echo "--- CONTRÔLE QUALITÉ : documents en erreur de parsing (DOIT valoir 0) ---"
es -H 'Content-Type: application/json' \
  "${ES_URL}/logs-shopflow_apache.access_json-${NS}/_count" \
  -d '{"query":{"bool":{"should":[{"exists":{"field":"error.message"}},{"term":{"tags":"json_parse_failed"}}],"minimum_should_match":1}}}'
echo
echo "--- CONTRÔLE QUALITÉ : documents SANS champ de durée (doit rester marginal) ---"
es -H 'Content-Type: application/json' \
  "${ES_URL}/logs-shopflow_apache.access_json-${NS}/_count" \
  -d '{"query":{"bool":{"must_not":[{"exists":{"field":"event.duration"}}]}}}'
echo
echo "═══ Terminé pour ${HOTE} ═══"
