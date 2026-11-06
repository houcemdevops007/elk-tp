#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  INCIDENT 2 — Le backend devient lent, sans aucune erreur ({{STUDENT_ID}})
#
#  Deux mécanismes combinables :
#    A) la requête non bornée du fil rouge (/api/cart?scenario=degrade) :
#       142 000 articles, ~4 s, ~180 Ko, code 200 ;
#    B) le throttling CPU : limite abaissée à 50 millicœurs.
#
#  Usage :  ./02-backend-lent.sh [A|B|AB] [duree_s]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="{{KUBECONFIG}}"
NS="{{NAMESPACE}}"
MODE="${1:-AB}"
DUREE="${2:-600}"
BASE="http://localhost:{{NODE_PORT}}"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · début de l'incident 2 (mode $MODE) =="

case "$MODE" in
  *A*) curl -s -o /dev/null "${BASE}/api/cart?scenario=degrade"
       echo "  [A] requête non bornée activée" ;;
esac
case "$MODE" in
  *B*) kubectl -n "$NS" set resources deploy/shopflow-app --limits=cpu=50m,memory=768Mi
       kubectl -n "$NS" rollout status deploy/shopflow-app --timeout=180s
       echo "  [B] limite CPU abaissée à 50m : throttling" ;;
esac

cat <<'FIN'
Ce que le candidat doit observer :
  1. P95 et P99 du frontal qui montent, P50 qui bouge moins
  2. AUCUN code d'erreur au début... puis des 504 quand la durée dépasse
     ProxyTimeout (10 s) : la lenteur du backend devient une ERREUR du frontal
  3. taille des réponses en forte hausse (mode A)
  4. cpu.usage.limit.pct en plateau près de 1 (mode B)
  5. AUCUN redémarrage, pods Ready : tous les indicateurs de disponibilité
     restent au vert
  6. SLO de latence violé AVANT le SLO de disponibilité
FIN

sleep "$DUREE"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · rétablissement =="
curl -s -o /dev/null "${BASE}/api/cart?scenario=normal" || true
kubectl -n "$NS" set resources deploy/shopflow-app --limits=cpu=1,memory=768Mi
kubectl -n "$NS" rollout status deploy/shopflow-app --timeout=180s
echo "== incident 2 terminé =="
