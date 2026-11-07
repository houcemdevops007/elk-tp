#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  remplir-variables.sh — remplace les marqueurs {{VARIABLE}} du chapitre 2
#  quand le générateur ne l'a pas fait.
#
#  Usage :  cd ~/tp-elk/02-tomcat && bash remplir-variables.sh
#           DRY_RUN=1 bash remplir-variables.sh     # simulation
#
#  NE TOUCHE PAS :
#    - generateur.html / generateur.json : ce sont les modèles du générateur ;
#    - chapitre.md : le texte du cours ;
#    - les variables Mustache d'Elasticsearch dans les pipelines :
#      {{{url.original}}}, {{{data_stream.namespace}}}, {{ _ingest... }}
#      (triples accolades ou minuscules : elles DOIVENT rester telles quelles).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Valeurs pour CETTE VM : vérifiez-les avant de lancer ───────────────────
declare -A V=(
  [STUDENT_ID]="student20"
  [NAMESPACE]="student20"
  [STUDENT_HOST]="$(hostname)"          # host.name tel que vu par l'agent
  [POLICY]="efi-student20-tomcat"
  [POLICY_HOTE]="efi-student20-apache"

  [CATALINA_HOME]="/opt/tomcat"
  [CATALINA_LOGS]="/opt/tomcat/logs"
  [TOMCAT_USER]="tomcat"
  [TOMCAT_PORT]="8080"
  [APP_CONTEXT]="shopflow-api"           # cf. ProxyPass /api/ → /shopflow-api/api/
  [TIMEZONE]="UTC"                       # fuseau de la VM (timedatectl)

  [HEAP_MB]="256"                        # petite heap volontaire pour le TP
  [JMX_PORT]="9999"
  [JOLOKIA_PORT]="8778"                  # port par défaut de Jolokia
  [JOLOKIA_JAR]="/opt/jolokia/jolokia-agent.jar"   # à adapter au fichier réel

  # Non devinables : à renseigner, sinon laissés tels quels (voir le message final)
  [ES_URL]="${ES_URL:-}"
  [CA_PATH]="${CA_PATH:-}"
  [ES_API_KEY]="${ES_API_KEY:-}"
)
DRY_RUN="${DRY_RUN:-0}"

[[ -d app && -d configs ]] || { echo "❌ Lancez ce script depuis ~/tp-elk/02-tomcat"; exit 1; }

mapfile -t FICHIERS < <(grep -rlE '\{\{[A-Z_]+\}\}' . \
  --exclude='generateur.html' --exclude='generateur.json' --exclude='chapitre.md' \
  --exclude='remplir-variables.sh' || true)

echo "Fichiers concernés : ${#FICHIERS[@]}"
for var in "${!V[@]}"; do
  val="${V[$var]}"
  n=$(grep -o "{{${var}}}" "${FICHIERS[@]}" 2>/dev/null | wc -l || true)
  [[ "$n" -eq 0 ]] && continue
  if [[ -z "$val" ]]; then
    echo "  ⏭  {{${var}}} ×${n} : aucune valeur fournie, laissé tel quel"; continue
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  🔎 {{${var}}} ×${n} → ${val}"
  else
    esc=$(printf '%s' "$val" | sed 's/[&|\\]/\\&/g')
    sed -i "s|{{${var}}}|${esc}|g" "${FICHIERS[@]}"
    echo "  ✅ {{${var}}} ×${n} → ${val}"
  fi
done

# Nettoyage d'un WAR construit avec un nom non remplacé
[[ "$DRY_RUN" != "1" && -f "app/{{APP_CONTEXT}}.war" ]] && rm -f "app/{{APP_CONTEXT}}.war" \
  && echo "  🧹 app/{{APP_CONTEXT}}.war supprimé (à reconstruire)"

echo
echo "Marqueurs restants (hors générateur et cours) :"
grep -rnoE '\{\{[A-Z_]+\}\}' . --exclude='generateur.html' --exclude='generateur.json' \
  --exclude='chapitre.md' --exclude='remplir-variables.sh' | sort -u || echo "  aucun ✅"
