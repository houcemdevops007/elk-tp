#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  parcours.sh — la séquence complète du chapitre 2, pour {{STUDENT_ID}}
#  À dérouler étape par étape, en vérifiant après chacune.
# ─────────────────────────────────────────────────────────────────────────────

# ÉTAPE 1 — Prérequis --------------------------------------------------------
sudo systemctl status tomcat --no-pager | head -5
ls {{CATALINA_HOME}}/{bin,conf,logs,webapps}
ls {{CATALINA_HOME}}/lib | grep -i servlet      # jakarta (Tomcat 10+) ou javax (9)
java -version 2>&1 | head -1
id {{TOMCAT_USER}}
df -h {{CATALINA_LOGS}} | tail -1               # un dump pèse autant que la heap

# ÉTAPE 2 — Journaux et options JVM ------------------------------------------
sudo cp {{CATALINA_HOME}}/conf/server.xml{,.avant-tp}
sudo cp {{CATALINA_HOME}}/conf/logging.properties{,.avant-tp}
#   reporter le bloc <Valve> de server-xml-host.xml dans <Host name="localhost">
sudo install -m 750 -o {{TOMCAT_USER}} -g {{TOMCAT_USER}} setenv.sh {{CATALINA_HOME}}/bin/setenv.sh
sudo install -m 644 logrotate-tomcat /etc/logrotate.d/tomcat
sudo systemctl restart tomcat
sleep 20

# ✅ Vérification
PID=$(pgrep -f catalina | head -1) ; echo "PID=$PID"
sudo -u {{TOMCAT_USER}} jcmd "$PID" VM.flags | tr ' ' '\n' | grep -E 'HeapSize|UseG1GC|HeapDump'
sudo tail -5 {{CATALINA_LOGS}}/gc.log
sudo tail -3 {{CATALINA_LOGS}}/localhost_access_log.*.txt

# ÉTAPE 3 — Application de démonstration -------------------------------------
cd app && ./build-war.sh && sudo ./deploy-war.sh && cd ..
curl -s http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}/health ; echo
curl -s http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}/api/cart | head -c 120 ; echo

# ÉTAPE 4 — Pipelines (Kibana -> Dev Tools -> Console) -----------------------
#   PUT  _ingest/pipeline/logs-shopflow_tomcat.access@custom      <- pipeline-tomcat-access.json
#   PUT  _ingest/pipeline/logs-shopflow_tomcat.catalina@custom    <- pipeline-tomcat-catalina.json
#   POST .../_simulate                                            <- pipeline-tomcat-simulate.json
#   Attendu : event.duration = 4102000000 ns (et NON 4102000)

# ÉTAPE 5 — Intégrations dans la politique {{POLICY}} ------------------------
#   Fleet -> Agent policies -> {{POLICY}} -> Add integration
#     a) Apache Tomcat si elle existe dans le catalogue, sinon Custom Logs :
#          {{CATALINA_LOGS}}/localhost_access_log.*.txt   dataset shopflow_tomcat.access
#          {{CATALINA_LOGS}}/catalina.out                 dataset shopflow_tomcat.catalina
#          {{CATALINA_LOGS}}/catalina.*.log               dataset shopflow_tomcat.catalina
#          {{CATALINA_LOGS}}/localhost.*.log              dataset shopflow_tomcat.localhost
#        + coller custom-logs-multiline.yml dans « Custom configurations »
#     b) Jolokia : http://127.0.0.1:{{JOLOKIA_PORT}}/jolokia, mappings de
#        jolokia-mappings.yml

# ✅ Vérification
sudo elastic-agent status --output=full | head -40
ES_API_KEY='<votre-cle>' ./scripts/verif-tomcat.sh

# ÉTAPE 6 — Scénarios --------------------------------------------------------
./scripts/scenario-lenteur.sh B 180        # requête non bornée : 200 et pourtant lent
./scripts/scenario-fuite.sh 10 10          # fuite jusqu'à l'OutOfMemoryError
sudo systemctl restart tomcat              # remise en état après l'OOM
./scripts/scenario-deploiement.sh          # échec de déploiement

# ÉTAPE 7 — Nettoyage --------------------------------------------------------
curl -s http://localhost:{{TOMCAT_PORT}}/{{APP_CONTEXT}}/api/reset ; echo
sudo logrotate -f /etc/logrotate.d/tomcat
sudo rm -f {{CATALINA_LOGS}}/heapdump.hprof     # un dump peut contenir des données
