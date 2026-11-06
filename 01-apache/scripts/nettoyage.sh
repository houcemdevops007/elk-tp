#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  nettoyage.sh — remise en état de la VM de {{STUDENT_ID}} en fin de chapitre
#
#  Ce script NE supprime AUCUNE donnée dans Elasticsearch : la rétention est
#  gérée par l'ILM de la plateforme (opération formateur). Il remet seulement
#  la VM dans un état propre.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

echo "== 1. Rétablir Apache dans un état sain =="
sudo apachectl configtest
sudo systemctl reload apache2
sudo systemctl is-active apache2

echo "== 2. Vérifier que l'agent est sain avant de partir =="
sudo elastic-agent status || true

echo "== 3. Libérer l'espace des journaux locaux (forcer une rotation) =="
sudo logrotate -f /etc/logrotate.d/apache2
du -sh {{APACHE_LOG_DIR}}

echo "== 4. À FAIRE À LA MAIN dans Kibana, en fin de formation =="
cat <<'FIN'
  - Désactiver vos règles d'alerte : une règle oubliée continue de s'exécuter
    indéfiniment et consomme le cluster partagé.
  - Conserver vos dashboards : ils font partie de vos livrables.
  - Ne PAS désinstaller l'agent : les chapitres 2 à 4 s'appuient dessus.
    (désenrôlement éventuel : sudo elastic-agent uninstall)
FIN
