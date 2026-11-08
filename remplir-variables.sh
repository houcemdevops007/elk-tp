#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  remplir-variables.sh — personnalise les fichiers du chapitre 3 pour VOTRE
#  cluster. À lancer SUR LE MASTER, dans ~/tp-elk/03-kubernetes.
#
#  Usage :
#    bash scripts/remplir-variables.sh student07              # simulation d'abord
#    bash scripts/remplir-variables.sh student07 --appliquer  # remplacement réel
#
#  Surcharges possibles (variables d'environnement) :
#    DEMO_IMAGE=miroir.local/busybox:1.36 ES_VERSION=9.5.6 bash …
#
#  Ne touche ni generateur.html, ni generateur.json, ni chapitre.md.
#  Rejouable sans risque : un fichier déjà personnalisé n'est plus modifié.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STUDENT="${1:-}"
MODE="${2:-}"
if [[ ! "$STUDENT" =~ ^student[0-9]{2}$ ]]; then
  echo "Usage : bash $0 studentXX [--appliquer]      (ex. : student07)"; exit 1
fi
APPLIQUER=0; [[ "$MODE" == "--appliquer" ]] && APPLIQUER=1

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RACINE"
[[ -d manifests && -d scenarios ]] || { echo "❌ Dossier du chapitre 3 introuvable ($RACINE)"; exit 1; }

WORKER=$(kubectl get nodes --no-headers 2>/dev/null | awk '$3 !~ /control-plane/ {print $1; exit}' || true)

declare -A V=(
  [STUDENT_ID]="$STUDENT"
  [NAMESPACE]="$STUDENT"
  [POLICY]="efi-${STUDENT}-apache"
  [POLICY_K8S]="efi-${STUDENT}-k8s"
  [KUBECONFIG]="${KUBECONFIG:-$HOME/.kube/config}"
  [DEMO_IMAGE]="${DEMO_IMAGE:-busybox:1.36}"
  [KSM_VERSION]="${KSM_VERSION:-v2.14.0}"
  [ES_VERSION]="${ES_VERSION:-9.5.6}"
  [ES_URL]="${ES_URL:-}"
  [CA_PATH]="${CA_PATH:-}"
  [ES_API_KEY]="${ES_API_KEY:-}"
)

echo "== Valeurs pour ${STUDENT} =="
for k in STUDENT_ID NAMESPACE POLICY_K8S KUBECONFIG DEMO_IMAGE KSM_VERSION ES_VERSION; do
  printf "   %-12s %s\n" "$k" "${V[$k]}"
done
printf "   %-12s %s\n" "(worker)" "${WORKER:-introuvable : kubectl fonctionne-t-il ?}"
echo

EXCL=(--exclude='generateur.html' --exclude='generateur.json' --exclude='chapitre.md'
      --exclude='remplir-variables.sh')
mapfile -t FICHIERS < <(grep -rlE '\{\{[A-Z_0-9]+\}\}' . "${EXCL[@]}" || true)
if [[ ${#FICHIERS[@]} -eq 0 ]]; then
  echo "✅ Aucun marqueur à remplacer : les fichiers sont déjà personnalisés."; exit 0
fi

echo "== $( [[ $APPLIQUER == 1 ]] && echo Remplacement || echo "Simulation (rien n'est modifié)" ) — ${#FICHIERS[@]} fichiers =="
for var in "${!V[@]}"; do
  val="${V[$var]}"
  n=$(cat "${FICHIERS[@]}" | grep -o "{{${var}}}" | wc -l || true)
  [[ "$n" -eq 0 ]] && continue
  if [[ -z "$val" ]]; then
    echo "   ⏭  {{${var}}} ×${n} : pas de valeur (verif-k8s.sh seulement, plus tard)"; continue
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
  echo; echo "Marqueurs restants :"
  grep -rnoE '\{\{[A-Z_0-9]+\}\}' . "${EXCL[@]}" | sort -u || echo "   aucun ✅"
else
  echo; echo "Si les valeurs sont correctes : bash $0 ${STUDENT} --appliquer"
fi
