#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  scenario-fuite.sh — fuite mémoire volontaire jusqu'à l'OutOfMemoryError
#  Candidat : {{STUDENT_ID}}   À lancer UNIQUEMENT sur votre VM Tomcat.
#
#  Principe : la route /api/fuite retient N Mo dans une collection statique
#  qui n'est jamais vidée. Chaque GC libère donc de moins en moins.
#
#  Usage :  ./scenario-fuite.sh [mo_par_appel] [intervalle_s]
#  Retour à la normale : sudo systemctl restart tomcat
#                        curl http://localhost:PORT/CTX/api/reset
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

MO="${1:-10}"
INTERVALLE="${2:-10}"
BASE="http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}"
LOGS="{{CATALINA_LOGS}}"
TUSER="{{TOMCAT_USER}}"
HEAP_PREVU="{{HEAP_MB}}"

# Le processus Tomcat lui-même (et non un « tail -f catalina.out » ouvert ailleurs)
PID="$(pgrep -f 'org.apache.catalina.startup.Bootstrap' | head -1 || true)"
[ -n "$PID" ] || { echo "[ERREUR] Tomcat ne tourne pas."; exit 1; }

# jstat et jcmd doivent venir du MÊME JDK que la JVM observée
JDK_BIN="$(dirname "$(readlink -f "/proc/$PID/exe")")"
JSTAT="$JDK_BIN/jstat"; JCMD="$JDK_BIN/jcmd"
[ -x "$JSTAT" ] || { echo "[ERREUR] jstat introuvable dans $JDK_BIN (installer le JDK, pas seulement le JRE)"; exit 1; }

# Heap réellement appliquée : si setenv.sh n'est pas en place, la heap par
# défaut (1/4 de la RAM) rend le scénario très long.
HEAP_REEL=$(sudo -u "$TUSER" "$JCMD" "$PID" VM.flags 2>/dev/null \
            | tr ' ' '\n' | sed -n 's/^-XX:MaxHeapSize=//p' | head -1)
HEAP_REEL_MB=$(( ${HEAP_REEL:-0} / 1024 / 1024 ))
echo "== Heap maximale appliquée : ${HEAP_REEL_MB} Mo (prévue : ${HEAP_PREVU} Mo) =="
if [ "$HEAP_REEL_MB" -gt $(( HEAP_PREVU * 2 )) ] 2>/dev/null; then
  echo "   ⚠️  setenv.sh ne semble pas appliqué : l'OOM arrivera après environ"
  echo "      $(( HEAP_REEL_MB / MO * INTERVALLE / 60 )) minutes. Vérifiez l'étape 2.2."
fi

# On ne surveille que les NOUVELLES lignes de catalina.out : un OOM d'une
# exécution précédente ne doit pas arrêter le script dès le premier tour.
DEBUT=$(sudo stat -c %s "${LOGS}/catalina.out" 2>/dev/null || echo 0)

echo "== Fuite : ${MO} Mo toutes les ${INTERVALLE} s · PID $PID · début $(date -u '+%H:%M:%SZ') · Ctrl-C pour arrêter =="
echo
printf "%-10s %-8s %-8s %-8s %-8s %-8s %-10s\n" "heure" "retenu" "O(%)" "E(%)" "M(%)" "FGC" "GCT(s)"

i=0
while true; do
  i=$((i + 1))
  RETENU=$(curl -s -m 60 "${BASE}/api/fuite?mo=${MO}" \
           | python3 -c 'import json,sys; print(json.load(sys.stdin).get("retenu_mo","?"))' 2>/dev/null || echo "OOM?")

  # jstat -gcutil : O = Old en %, E = Eden, M = Metaspace,
  #                 FGC = nombre de full GC, GCT = temps TOTAL passé en GC.
  # Ce qui compte n'est pas le NOMBRE de GC mais le TEMPS passé en GC.
  LIGNE=$(sudo -u "$TUSER" "$JSTAT" -gcutil "$PID" 2>/dev/null | tail -1)
  O=$(echo "$LIGNE" | awk '{print $4}')
  E=$(echo "$LIGNE" | awk '{print $3}')
  M=$(echo "$LIGNE" | awk '{print $5}')
  FGC=$(echo "$LIGNE" | awk '{print $8}')
  GCT=$(echo "$LIGNE" | awk '{print $NF}')
  printf "%-10s %-8s %-8s %-8s %-8s %-8s %-10s\n" \
    "$(date -u '+%H:%M:%S')" "${RETENU}Mo" "$O" "$E" "$M" "$FGC" "$GCT"

  if sudo tail -c +$((DEBUT + 1)) "${LOGS}/catalina.out" 2>/dev/null | grep -q 'OutOfMemoryError'; then
    echo
    echo "== OutOfMemoryError détecté à $(date -u '+%H:%M:%SZ') =="
    sudo tail -c +$((DEBUT + 1)) "${LOGS}/catalina.out" | grep -h -m3 'OutOfMemoryError'
    echo "--- un dump a-t-il été produit ? ---"
    sudo ls -lh "${LOGS}"/heapdump.hprof 2>/dev/null \
      || echo "  aucun dump : vérifiez -XX:+HeapDumpOnOutOfMemoryError (setenv.sh), l'espace disque et les droits sur ${LOGS}"
    echo
    echo "À relever dans votre compte rendu :"
    echo "  - le MESSAGE exact de l'OOM (Java heap space ? GC overhead limit exceeded ?)"
    echo "  - le nombre d'appels avant la bascule : $i (soit $((i * MO)) Mo demandés)"
    echo "  - la taille du dump, à comparer à la heap (${HEAP_REEL_MB} Mo)"
    echo "Puis : sudo systemctl restart tomcat && curl ${BASE}/api/reset"
    exit 0
  fi
  sleep "$INTERVALLE"
done
