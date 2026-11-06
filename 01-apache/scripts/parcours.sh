#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  parcours.sh — la séquence complète du chapitre 1, pour {{STUDENT_ID}}
#
#  À dérouler étape par étape (et non d'un bloc) : chaque étape se vérifie
#  avant de passer à la suivante. Les fichiers référencés sont ceux produits
#  par le générateur du chapitre.
# ─────────────────────────────────────────────────────────────────────────────

# ÉTAPE 1 — Prérequis Apache -------------------------------------------------
apache2 -v                                  # version
apache2ctl -M | grep -E 'mpm|status|proxy|unique|headers'
apache2ctl -V | grep -i 'MPM\|Server MPM'   # prefork / worker / event
ls -l {{APACHE_LOG_DIR}}/
sudo a2enmod status unique_id headers
sudo mkdir -p /var/www/shopflow/assets
echo '{"status":"UP","service":"shopflow-web","student":"{{STUDENT_ID}}"}' \
  | sudo tee /var/www/shopflow/health.json >/dev/null

# ÉTAPE 2 — Journalisation et mod_status -------------------------------------
sudo install -m 644 shopflow-logs.conf    /etc/apache2/conf-available/
sudo install -m 644 server-status.conf    /etc/apache2/conf-available/
sudo install -m 644 shopflow-vhost.conf   /etc/apache2/sites-available/shopflow.conf
sudo install -m 644 logrotate-apache      /etc/logrotate.d/apache2
sudo a2enconf shopflow-logs server-status
sudo a2ensite shopflow
sudo apachectl configtest                   # DOIT afficher : Syntax OK
sudo systemctl reload apache2               # reload, jamais restart à l'aveugle

# ✅ Vérification
curl -s -o /dev/null http://localhost/
sudo tail -1 {{APACHE_LOG_DIR}}/access.log
sudo tail -1 {{APACHE_LOG_DIR}}/access_json.log | python3 -m json.tool
curl -s "http://localhost/server-status?auto" | head -9
#   depuis votre poste, l'accès distant DOIT être refusé (403) :
#   curl -I http://{{STUDENT_IP}}/server-status

# ÉTAPE 3 — Pipeline @custom (Kibana -> Dev Tools -> Console) ----------------
#   1. coller le contenu de pipeline-access-json.json après
#      PUT _ingest/pipeline/logs-shopflow_apache.access_json@custom
#   2. coller pipeline-simulate.json après
#      POST _ingest/pipeline/logs-shopflow_apache.access_json@custom/_simulate
#   3. vérifier dans la réponse : event.duration = 4102311000 (ns)

# ÉTAPE 4 — Agent Elastic ----------------------------------------------------
sudo ./install-agent.sh '<votre-token-d-enrolement>'
sudo elastic-agent status --output=full
sudo elastic-agent inspect | grep -A4 -i paths

# ÉTAPE 5 — Trafic, recherche, dashboard, alertes ----------------------------
chmod +x gen-trafic.sh verif-ingestion.sh
./gen-trafic.sh http://localhost normal 60
ES_API_KEY='<votre-cle-api>' ./verif-ingestion.sh

# ÉTAPE 6 — Scénarios --------------------------------------------------------
./gen-trafic.sh http://localhost erreurs 90
./gen-trafic.sh http://localhost flood404
./gen-trafic.sh http://localhost lenteur
./gen-trafic.sh http://localhost charge
./gen-trafic.sh http://localhost arret

# ÉTAPE 7 — Nettoyage --------------------------------------------------------
chmod +x nettoyage.sh && ./nettoyage.sh
