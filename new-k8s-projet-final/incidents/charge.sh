#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  charge.sh — trafic nominal sur ShopFlow trois tiers ({{STUDENT_ID}})
#
#  Fait vivre le parcours complet : frontal -> backend -> base. À laisser
#  tourner en continu pendant tout le projet : sans trafic, aucun SLI n'a
#  de sens, et un incident ne produit aucun signal.
#
#  Usage :  ./charge.sh [duree_s] [req_par_seconde]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

BASE="http://localhost:{{NODE_PORT}}"
DUREE="${1:-600}"
RPS="${2:-4}"
FIN=$(( $(date +%s) + DUREE ))
PAUSE=$(python3 -c "print(1.0/max(1,$RPS))")

echo "== charge sur $BASE pendant ${DUREE}s, ~${RPS} req/s =="
OK=0 ; KO=0
while [ "$(date +%s)" -lt "$FIN" ]; do
  for ROUTE in / /api/cart /api/produit/42 /api/db /api/commande; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${BASE}${ROUTE}")
    if [ "$CODE" -ge 500 ] 2>/dev/null; then
      KO=$(( KO + 1 ))
    else
      OK=$(( OK + 1 ))
    fi
  done
  sleep "$PAUSE"
done
echo "== terminé : ${OK} succès, ${KO} erreurs serveur =="
