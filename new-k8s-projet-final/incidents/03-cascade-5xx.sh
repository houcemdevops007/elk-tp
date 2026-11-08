#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  INCIDENT 3 — Cascade de 5xx ({{STUDENT_ID}})
#
#  Mécanisme : le backend est mis en échec de démarrage (limite mémoire
#  incompatible avec la heap de la JVM -> OOMKilled en boucle). Le frontal
#  n'a plus de backend joignable et renvoie des 502 et 503.
#
#  C'est l'incident le plus riche : trois tiers, trois symptômes différents,
#  une seule cause. Et il démontre la règle de lecture des codes :
#    502 = le backend a répondu n'importe quoi ou a coupé
#    503 = plus aucune ressource disponible pour traiter
#    504 = le backend est vivant mais trop lent
#
#  Usage :  ./03-cascade-5xx.sh [duree_s]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="{{KUBECONFIG}}"
NS="{{NAMESPACE}}"
DUREE="${1:-600}"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · début de l'incident 3 =="
#  La heap demandée ({{HEAP_MB}} Mo) dépasse désormais la limite du
#  conteneur : la JVM est tuée par le noyau dès qu'elle la réclame.
kubectl -n "$NS" set resources deploy/shopflow-app --limits=memory=160Mi,cpu=1
kubectl -n "$NS" get pods -l app.kubernetes.io/component=backend -w &
WATCH=$!
sleep 90
kill "$WATCH" 2>/dev/null || true

cat <<'FIN'
Ce que le candidat doit observer, tier par tier :
  frontal : 502 puis 503 ; error.log avec AH01114 « failed to make
            connection to backend » ; latence courte (échec rapide)
  backend : pods en boucle de redémarrage, last_terminated_reason =
            OOMKilled, AUCUNE OutOfMemoryError dans les logs Java
            (le noyau tue avant que la JVM ne puisse l'écrire)
  base    : parfaitement saine - c'est la preuve que la cause est au
            deuxième tier
La cause racine à formuler en une phrase : la limite mémoire du conteneur
(160 Mi) est inférieure à la mémoire totale réclamée par la JVM (heap de
{{HEAP_MB}} Mo + metaspace + piles de threads), donc le conteneur est tué
à chaque démarrage.
FIN

sleep "$DUREE"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · rétablissement =="
kubectl -n "$NS" set resources deploy/shopflow-app --limits=memory=768Mi,cpu=1
kubectl -n "$NS" rollout status deploy/shopflow-app --timeout=240s
curl -s "http://localhost:{{NODE_PORT}}/api/commande" ; echo
echo "== incident 3 terminé =="
