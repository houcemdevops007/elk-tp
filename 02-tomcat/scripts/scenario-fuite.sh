#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  scenario-fuite.sh — fuite mémoire volontaire jusqu'à l'OutOfMemoryError
#  Candidat : {{STUDENT_ID}}   À lancer UNIQUEMENT sur votre VM.
#
#  Principe : la route /api/fuite retient N Mo dans une collection statique
#  qui n'est jamais vidée. Chaque GC libère donc de moins en moins.
#
#  Usage :  ./scenario-fuite.sh [mo_par_appel] [intervalle_s]
#  Retour à la normale : curl http://localhost:PORT/CTX/api/reset
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

MO="${1:-10}"
INTERVALLE="${2:-10}"
BASE="http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}"
LOGS="{{CATALINA_LOGS}}"

PID="$(pgrep -f 'catalina' | head -1 || true)"
[ -n "$PID" ] || { echo "[ERREUR] Tomcat ne tourne pas."; exit 1; }

echo "== Fuite mémoire : ${MO} Mo toutes les ${INTERVALLE} s — heap = {{HEAP_MB}} Mo =="
echo "== PID $PID · début $(date -u '+%H:%M:%SZ') · Ctrl-C pour arrêter =="
echo
printf "%-10s %-8s %-8s %-8s %-8s %-8s %-10s\n" "heure" "retenu" "O(%)" "E(%)" "M(%)" "FGC" "GCT(s)"

i=0
while true; do
  i=$((i + 1))
  RETENU=$(curl -s "${BASE}/api/fuite?mo=${MO}" \
           | python3 -c 'import json,sys; print(json.load(sys.stdin).get("retenu_mo","?"))' 2>/dev/null || echo "OOM?")

  # jstat -gcutil : O = Old en %, E = Eden, M = Metaspace,
  #                 FGC = nombre de full GC, GCT = temps TOTAL passé en GC.
  # Ce qui compte n'est pas le NOMBRE de GC mais le TEMPS passé en GC.
  LIGNE=$(sudo -u "{{TOMCAT_USER}}" jstat -gcutil "$PID" 2>/dev/null | tail -1)
  O=$(echo "$LIGNE" | awk '{print $4}')
  E=$(echo "$LIGNE" | awk '{print $3}')
  M=$(echo "$LIGNE" | awk '{print $5}')
  FGC=$(echo "$LIGNE" | awk '{print $8}')
  GCT=$(echo "$LIGNE" | awk '{print $NF}')
  printf "%-10s %-8s %-8s %-8s %-8s %-8s %-10s\n" \
    "$(date -u '+%H:%M:%S')" "${RETENU}Mo" "$O" "$E" "$M" "$FGC" "$GCT"

  if sudo grep -q 'OutOfMemoryError' "${LOGS}/catalina.out" 2>/dev/null; then
    echo
    echo "== OutOfMemoryError détecté à $(date -u '+%H:%M:%SZ') =="
    sudo grep -h -m3 'OutOfMemoryError' "${LOGS}/catalina.out"
    echo "--- un dump a-t-il été produit ? ---"
    sudo ls -lh "${LOGS}"/heapdump.hprof 2>/dev/null \
      || echo "  aucun dump : vérifiez l'espace disque et les droits sur ${LOGS}"
    echo
    echo "À relever dans votre compte rendu :"
    echo "  - le MESSAGE exact de l'OOM (Java heap space ? GC overhead limit exceeded ?)"
    echo "  - le nombre d'appels avant la bascule : $i (soit $((i * MO)) Mo demandés)"
    echo "  - la taille du dump, à comparer à la heap ({{HEAP_MB}} Mo)"
    echo "Puis : sudo systemctl restart tomcat && curl ${BASE}/api/reset"
    exit 0
  fi
  sleep "$INTERVALLE"
done
