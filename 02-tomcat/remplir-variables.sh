#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  remplir-variables.sh — personnalise les fichiers du chapitre 2 pour VOTRE VM
#
#  Remplace les marqueurs {{VARIABLE}} (en MAJUSCULES) par les valeurs de votre
#  VM. Le numéro de candidat est demandé ; tout le reste est détecté.
#
#  Usage :
#    cd ~/tp-elk/02-tomcat
#    bash scripts/remplir-variables.sh student07              # simulation d'abord
#    bash scripts/remplir-variables.sh student07 --appliquer  # remplacement réel
#
#  Surcharges possibles (variables d'environnement) :
#    HEAP_MB=512 JOLOKIA_JAR=/chemin/jolokia.jar ES_URL=https://… bash …
#
#  NE TOUCHE PAS :
#    - generateur.html / generateur.json / chapitre.md ;
#    - les variables Mustache d'Elasticsearch dans les pipelines
#      ({{{url.original}}}, {{ _ingest.on_failure_message }}…) : elles DOIVENT
#      rester telles quelles. Seuls les marqueurs en MAJUSCULES sont remplacés.
#  Rejouable sans risque : un fichier déjà personnalisé n'est plus modifié.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STUDENT="${1:-}"
MODE="${2:-}"
if [[ ! "$STUDENT" =~ ^student[0-9]{2}$ ]]; then
  echo "Usage : bash $0 studentXX [--appliquer]      (ex. : student07)"; exit 1
fi
APPLIQUER=0; [[ "$MODE" == "--appliquer" ]] && APPLIQUER=1

# Se placer à la racine du chapitre, quel que soit l'endroit d'où l'on lance
RACINE="$(cd "$(dirname "$0")" && pwd)"; [[ -d "$RACINE/app" ]] || RACINE="$(dirname "$RACINE")"
cd "$RACINE"
[[ -d app && -d configs ]] || { echo "❌ Dossier du chapitre 2 introuvable ($RACINE)"; exit 1; }

# ─── Détection sur la VM ────────────────────────────────────────────────────
PID=$(pgrep -f 'org.apache.catalina.startup.Bootstrap' | head -1 || true)
detect_home() {
  [[ -n "$PID" ]] || return 0
  tr '\0' '\n' < "/proc/$PID/cmdline" 2>/dev/null | sed -n 's/^-Dcatalina.home=//p' | head -1 || true
}
CATALINA_HOME="${CATALINA_HOME:-$(detect_home)}"
CATALINA_HOME="${CATALINA_HOME:-/opt/tomcat}"
if [[ -z "${TOMCAT_USER:-}" ]]; then
  TOMCAT_USER=tomcat
  [[ -n "$PID" ]] && TOMCAT_USER=$(ps -o user= -p "$PID" | tr -d ' ')
fi
TOMCAT_PORT="${TOMCAT_PORT:-$(grep -oP '<Connector[^>]*port="\K[0-9]+(?="[^>]*protocol="HTTP/1\.1")' \
                "$CATALINA_HOME/conf/server.xml" 2>/dev/null | head -1 || true)}"
TOMCAT_PORT="${TOMCAT_PORT:-8080}"
TZ_VM="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
[[ "$TZ_VM" == "Etc/UTC" ]] && TZ_VM="UTC"

declare -A V=(
  [STUDENT_ID]="$STUDENT"
  [NAMESPACE]="$STUDENT"
  [STUDENT_HOST]="$(hostname)"
  [POLICY]="efi-${STUDENT}-tomcat"
  [POLICY_HOTE]="efi-${STUDENT}-apache"
  [CATALINA_HOME]="$CATALINA_HOME"
  [CATALINA_LOGS]="${CATALINA_LOGS:-$CATALINA_HOME/logs}"
  [TOMCAT_USER]="$TOMCAT_USER"
  [TOMCAT_PORT]="$TOMCAT_PORT"
  [APP_CONTEXT]="${APP_CONTEXT:-shopflow-api}"
  [TIMEZONE]="${TIMEZONE:-$TZ_VM}"
  [HEAP_MB]="${HEAP_MB:-256}"
  [JMX_PORT]="${JMX_PORT:-9999}"
  [JOLOKIA_PORT]="${JOLOKIA_PORT:-8778}"
  [JOLOKIA_JAR]="${JOLOKIA_JAR:-/opt/jolokia/jolokia-agent.jar}"
  [ES_URL]="${ES_URL:-}"
  [CA_PATH]="${CA_PATH:-}"
  [ES_API_KEY]="${ES_API_KEY:-}"
)

echo "== Valeurs pour ${STUDENT} =="
for k in STUDENT_ID STUDENT_HOST CATALINA_HOME CATALINA_LOGS TOMCAT_USER TOMCAT_PORT \
         APP_CONTEXT TIMEZONE HEAP_MB JMX_PORT JOLOKIA_PORT JOLOKIA_JAR POLICY POLICY_HOTE; do
  printf "   %-14s %s\n" "$k" "${V[$k]}"
done
[[ -z "$PID" ]] && echo "   ⚠️  Tomcat ne tourne pas : valeurs par défaut utilisées (vérifiez-les)."
echo

EXCL=(--exclude='generateur.html' --exclude='generateur.json' --exclude='chapitre.md'
      --exclude='remplir-variables.sh')
mapfile -t FICHIERS < <(grep -rlE '\{\{[A-Z_]+\}\}' . "${EXCL[@]}" || true)
if [[ ${#FICHIERS[@]} -eq 0 ]]; then
  echo "✅ Aucun marqueur à remplacer : les fichiers sont déjà personnalisés."; exit 0
fi

echo "== $( [[ $APPLIQUER == 1 ]] && echo Remplacement || echo "Simulation (rien n’est modifié)" ) — ${#FICHIERS[@]} fichiers =="
for var in "${!V[@]}"; do
  val="${V[$var]}"
  n=$(cat "${FICHIERS[@]}" | grep -o "{{${var}}}" | wc -l || true)
  [[ "$n" -eq 0 ]] && continue
  if [[ -z "$val" ]]; then
    echo "   ⏭  {{${var}}} ×${n} : pas de valeur (inutile pour l'instant)"; continue
  fi
  if [[ "$APPLIQUER" == "1" ]]; then
    esc=$(printf '%s' "$val" | sed 's/[&|\\]/\\&/g')
    sed -i "s|{{${var}}}|${esc}|g" "${FICHIERS[@]}"
    echo "   ✅ {{${var}}} ×${n} → ${val}"
  else
    echo "   🔎 {{${var}}} ×${n} → ${val}"
  fi
done

if [[ "$APPLIQUER" == "1" ]]; then
  [[ -f "app/{{APP_CONTEXT}}.war" ]] && rm -f "app/{{APP_CONTEXT}}.war" \
    && echo "   🧹 app/{{APP_CONTEXT}}.war supprimé (à reconstruire)"
  echo
  echo "Marqueurs restants :"
  grep -rnoE '\{\{[A-Z_]+\}\}' . "${EXCL[@]}" | sort -u || echo "   aucun ✅"
  echo "(ES_URL, CA_PATH, ES_API_KEY ne servent qu'à scripts/verif-tomcat.sh, plus tard.)"
else
  echo
  echo "Si les valeurs sont correctes, relancez avec --appliquer :"
  echo "   bash $0 ${STUDENT} --appliquer"
fi
