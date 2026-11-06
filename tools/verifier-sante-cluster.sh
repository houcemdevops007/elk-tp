#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verifier-sante-cluster.sh — pourquoi une recherche Kibana expire
#
#  Un « Timed out » dans Discover n'est presque jamais un problème de Discover.
#  Les causes, par fréquence : cluster dégradé (shards non assignés après un
#  redémarrage), disque au-delà du seuil de vigilance, motif d'index trop large
#  sur une fenêtre trop longue, ou nœud absent.
#
#  Ce script lit l'état du cluster — EN LECTURE SEULE — et conclut.
#
#  Usage :
#    ES_API_KEY='<cle>' ./verifier-sante-cluster.sh [url-es] [chemin-ca]
#    ./verifier-sante-cluster.sh https://172.16.3.50:9200 ~/efi-elk-platform/pki/ca.crt
#    (sans clé d'API : exporte ES_USER=elastic, le mot de passe sera demandé)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES="${1:-https://172.16.3.50:9200}"
CA="${2:-$HOME/efi-elk-platform/pki/ca.crt}"

AUTH=()
if [ -n "${ES_API_KEY:-}" ]; then
  AUTH=(-H "Authorization: ApiKey ${ES_API_KEY}")
elif [ -n "${ES_USER:-}" ]; then
  AUTH=(-u "${ES_USER}")
fi
CACERT=()
[ -f "$CA" ] && CACERT=(--cacert "$CA")

es() { curl -sS --max-time 20 "${CACERT[@]}" "${AUTH[@]}" "$ES$1"; }

echo "═══ Cluster : $ES ═══"
echo
echo "── 1. Santé globale ──"
SANTE=$(es "/_cluster/health")
echo "$SANTE" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("   [ÉCHEC] réponse illisible : authentification ou CA ?"); raise SystemExit(1)
etat = d.get("status", "?")
print(f"   statut                     : {etat.upper()}")
for c, l in [("number_of_nodes","nœuds"), ("number_of_data_nodes","nœuds de données"),
             ("active_primary_shards","shards primaires actifs"),
             ("relocating_shards","en relocalisation"), ("initializing_shards","en initialisation"),
             ("unassigned_shards","NON ASSIGNÉS"), ("number_of_pending_tasks","tâches en attente")]:
    print(f"   {l:<26} : {d.get(c)}")
if etat == "red":
    print("   [!] ROUGE : des données sont INDISPONIBLES. Toute recherche les touchant échoue.")
elif etat == "yellow":
    print("   [i] JAUNE : les réplicas manquent. Les recherches fonctionnent, sans redondance.")
if d.get("unassigned_shards", 0):
    print("   [!] Des shards non assignés : voir l'\''étape 4 pour la raison.")
if d.get("initializing_shards", 0) or d.get("relocating_shards", 0):
    print("   [i] Le cluster se reconstruit : les recherches peuvent être LENTES le temps que ça finisse.")
'
echo
echo "── 2. Les nœuds répondent-ils, et dans quel état ? ──"
es "/_cat/nodes?v&h=name,ip,heap.percent,ram.percent,cpu,load_1m,disk.used_percent,master,node.role" \
  | sed 's/^/   /'
echo
echo "── 3. Espace disque et seuils ──"
es "/_cat/allocation?v&h=node,shards,disk.used,disk.avail,disk.total,disk.percent" | sed 's/^/   /'
echo "   Rappel des seuils par défaut : 85 % vigilance (plus d'allocation nouvelle),"
echo "   90 % haute (relocalisation forcée), 95 % index passés en lecture seule."
echo
echo "── 4. Shards en souffrance (vide = tout va bien) ──"
PB=$(es "/_cat/shards?v&h=index,shard,prirep,state,unassigned.reason,node" | awk 'NR==1 || $4!="STARTED"')
echo "$PB" | head -15 | sed 's/^/   /'
[ "$(echo "$PB" | wc -l)" -le 1 ] && echo "   tous les shards sont STARTED"
echo
echo "── 5. Les plus gros index (une recherche large les balaie tous) ──"
es "/_cat/indices?v&s=store.size:desc&h=index,health,status,docs.count,store.size" \
  | head -11 | sed 's/^/   /'
echo
echo "── 6. Tâches de recherche en cours depuis plus de 10 s ──"
es "/_tasks?actions=*search*&detailed=true" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("   (illisible)"); raise SystemExit
lentes = []
for noeud in d.get("nodes", {}).values():
    for t in noeud.get("tasks", {}).values():
        ms = t.get("running_time_in_nanos", 0) / 1e6
        if ms > 10000:
            lentes.append((ms, t.get("description", "")[:110]))
if not lentes:
    print("   aucune recherche longue en cours")
for ms, desc in sorted(lentes, reverse=True)[:5]:
    print(f"   {ms/1000:7.1f} s  {desc}")
'
echo
echo "── 7. Kibana : quel composant est dégradé ? ──"
#  Un « Timed out » dans Discover ou « Initialisation de Fleet impossible »
#  vient de KIBANA, pas d'Elasticsearch, dès lors que le cluster est vert.
#  /api/status nomme précisément le plugin en cause.
KBN="${KIBANA_URL:-https://172.16.3.53:5601}"
curl -sS --max-time 25 "${CACERT[@]}" "${AUTH[@]}" "$KBN/api/status" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("   [ECHEC] Kibana ne repond pas, ou authentification refusee")
    raise SystemExit
st = d.get("status", {}) or {}
globale = (st.get("overall") or {}).get("level", "?")
print("   etat global                : %s" % globale)
degrade = False
for section in ("core", "plugins"):
    for nom, v in (st.get(section) or {}).items():
        niveau = (v or {}).get("level")
        if niveau and niveau != "available":
            degrade = True
            resume = str((v or {}).get("summary", ""))[:110]
            print("   [!] %s/%-22s %s - %s" % (section, nom, niveau, resume))
if not degrade:
    print("   tous les composants Kibana sont disponibles")
'

echo
echo "── 8. Le registre d'intégrations est-il joignable ? ──"
#  Fleet contacte epr.elastic.co au démarrage pour le catalogue. Sur un réseau
#  fermé sans configuration hors-ligne, cet appel attend puis expire : c'est
#  une cause classique de « Initialisation de Fleet impossible ».
if curl -sS -I --max-time 8 https://epr.elastic.co >/dev/null 2>&1; then
  echo "   [OK] epr.elastic.co joignable depuis cette machine"
  echo "        (à retester DEPUIS elk-kibana0 : c'est lui qui l'appelle)"
else
  echo "   [!] epr.elastic.co INJOIGNABLE depuis cette machine."
  echo "       Si c'est aussi le cas depuis elk-kibana0, Fleet attend ce registre"
  echo "       au démarrage puis expire. Remèdes : autoriser la sortie, ou"
  echo "       déclarer le mode hors-ligne dans kibana.yml"
  echo "       (xpack.fleet.isAirGapped / registryUrl vers un miroir)."
fi
echo
echo "── Lecture ──"
cat <<'FIN'
   statut ROUGE ou shards non assignés -> c'est la cause : la recherche
       attend des données indisponibles. Traiter le cluster d'abord.
   disque au-delà de 85 % -> allocation bloquée, puis index en lecture
       seule à 95 %. Libérer de l'espace ou ajuster l'ILM.
   cluster VERT, disques sains, index volumineux -> c'est la REQUÊTE qui
       est trop large : réduisez la fenêtre (30 jours -> 24 heures) et
       ciblez un motif d'index précis plutôt que metrics-* ou logs-*.
   cluster VERT mais Kibana dégradé (étape 7) -> le problème est DANS
       Kibana : mémoire du processus, ou plugin en échec. Sur elk-kibana0 :
         sudo systemctl status kibana
         sudo journalctl -u kibana -n 100 --no-pager | grep -iE "error|timeout|fatal|heap"
         free -h
   registre injoignable (étape 8) -> Fleet attend epr.elastic.co au
       démarrage. C'est la cause la plus fréquente de « Initialisation de
       Fleet impossible » sur un réseau fermé.
FIN
