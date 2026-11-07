#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  scenario-lenteur.sh — application lente, sans AUCUNE erreur ({{STUDENT_ID}})
#
#  Deux formes de lenteur, à ne pas confondre :
#    A. latence artificielle maîtrisée  (/api/lent?ms=N)
#    B. requête non bornée du fil rouge (/api/cart?scenario=degrade) :
#       142 000 articles chargés, ~4 s, ~180 Ko de réponse, code 200.
#
#  Usage :  ./scenario-lenteur.sh [A|B] [duree_s]
#
#  Par défaut, les requêtes vont DIRECTEMENT à Tomcat. Pour passer par
#  Apache (et voir aussi l'effet côté proxy, workers et X-Request-Id) :
#     API=http://<IP_VM_APACHE>/api ./scenario-lenteur.sh B 180
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

FORME="${1:-B}"
DUREE="${2:-180}"
API="${API:-http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}/api}"
echo "== Cible : ${API} =="
FIN=$(( $(date +%s) + DUREE ))

case "$FORME" in
  A)
    echo "== Latence croissante : 6 paliers =="
    for ms in 200 500 900 1500 2500 4000; do
      echo "--- ${ms} ms demandés ---"
      for _ in $(seq 1 6); do
        curl -s -o /dev/null -w "  code %{http_code}  mesuré %{time_total}s\n" \
          "${API}/lent?ms=${ms}"
      done
    done
    ;;

  B)
    echo "== Fil rouge : dégradation du panier (requête non bornée) =="
    curl -s -o /dev/null "${API}/cart?scenario=degrade"
    date -u '+%Y-%m-%dT%H:%M:%SZ  début de la dégradation'
    while [ "$(date +%s)" -lt "$FIN" ]; do
      curl -s -o /dev/null -w "  cart : %{http_code}  %{time_total}s  %{size_download} octets\n" \
        "${API}/cart"
      curl -s -o /dev/null "${API}/produit/42"
      sleep 1
    done
    curl -s -o /dev/null "${API}/cart?scenario=normal"
    date -u '+%Y-%m-%dT%H:%M:%SZ  retour à la normale'
    ;;

  *) echo "usage : $0 [A|B] [duree_s]"; exit 1 ;;
esac

cat <<'FIN'

Ce que vous devez observer dans Kibana :
  - P95 et P99 qui montent, P50 qui bouge peu : une MINORITÉ de requêtes
    est touchée. (Si les trois montent ensemble, c'est une ressource
    saturée, pas une route lente.)
  - AUCUN code d'erreur : http.response.status_code reste à 200.
  - La taille des réponses qui augmente, corrélée à la lenteur.
  - Côté JVM : heap et GC NORMAUX. C'est une conclusion positive — elle
    innocente l'infrastructure et oriente vers le code.
  - Côté Apache (chapitre 1), SI vous êtes passé par Apache (variable API) :
    des workers occupés plus longtemps, voire des 504 si la durée dépasse
    ProxyTimeout. En appel direct, Apache ne voit rien.
FIN
