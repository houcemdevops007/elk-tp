#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  {{CATALINA_HOME}}/bin/setenv.sh — options JVM de ShopFlow ({{STUDENT_ID}})
#
#  C'est LE fichier où l'on met les options JVM. Jamais dans catalina.sh :
#  il est écrasé à chaque mise à jour de Tomcat.
#
#  Après modification :  sudo systemctl restart tomcat
#  Vérification        :  sudo -u {{TOMCAT_USER}} jcmd <PID> VM.flags
# ─────────────────────────────────────────────────────────────────────────────

# ─── Mémoire ────────────────────────────────────────────────────────────────
#  -Xms et -Xmx ÉGAUX : évite les redimensionnements et rend les courbes
#  lisibles. Valeur volontairement petite en TP ({{HEAP_MB}} Mo) : les
#  phénomènes de fuite et de GC excessif deviennent observables en quelques
#  minutes au lieu de plusieurs heures.
CATALINA_OPTS="$CATALINA_OPTS -Xms{{HEAP_MB}}m -Xmx{{HEAP_MB}}m"

# ─── Ramasse-miettes ────────────────────────────────────────────────────────
#  G1 est le GC par défaut des JVM modernes. On fixe un objectif de pause.
CATALINA_OPTS="$CATALINA_OPTS -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# ─── Journalisation du GC (unified logging, Java 9 et plus) ─────────────────
#  Indispensable au diagnostic : 5 fichiers de 20 Mo en rotation, bornés.
CATALINA_OPTS="$CATALINA_OPTS -Xlog:gc*:file={{CATALINA_LOGS}}/gc.log:time,uptime,level,tags:filecount=5,filesize=20M"

# ─── En cas d'OutOfMemoryError ──────────────────────────────────────────────
#  Le dump mémoire est la SEULE façon d'analyser une fuite après coup.
#  ATTENTION : un dump pèse autant que la heap. Vérifiez l'espace disque.
CATALINA_OPTS="$CATALINA_OPTS -XX:+HeapDumpOnOutOfMemoryError"
CATALINA_OPTS="$CATALINA_OPTS -XX:HeapDumpPath={{CATALINA_LOGS}}/heapdump.hprof"
#  Tuer la JVM sur OOM permet à systemd de la relancer proprement, au lieu de
#  laisser une JVM dans un état incohérent qui répond encore à moitié.
#  Conséquence : après un OOM, Tomcat s'arrête SANS la ligne
#  « Stopping service [Catalina] » et systemd le relance. C'est le
#  comportement attendu au scénario de fuite mémoire.
CATALINA_OPTS="$CATALINA_OPTS -XX:+ExitOnOutOfMemoryError"

# ─── JMX, pour la collecte de métriques JVM et Tomcat ───────────────────────
#  N'EXPOSEZ JAMAIS JMX SANS AUTHENTIFICATION SUR UNE INTERFACE PUBLIQUE :
#  JMX non authentifié permet l'exécution de code à distance. La
#  configuration ci-dessous n'est acceptable QUE parce que le port n'écoute
#  QUE sur 127.0.0.1 (option jmxremote.host). Attention : l'option
#  « local.only » ne suffit PAS, elle laisse le port ouvert sur toutes les
#  interfaces. Vérification : ss -ltnp | grep {{JMX_PORT}}  → 127.0.0.1:{{JMX_PORT}}
#
#  NB : jcmd et jstat n'ont PAS besoin de JMX (ils passent par l'API
#  d'attachement locale), Jolokia non plus (il tourne DANS la JVM).
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.host=127.0.0.1"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.port={{JMX_PORT}}"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.rmi.port={{JMX_PORT}}"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.local.only=true"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.authenticate=false"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.ssl=false"
CATALINA_OPTS="$CATALINA_OPTS -Djava.rmi.server.hostname=127.0.0.1"

# ─── Agent Jolokia : expose JMX en HTTP/JSON pour l'intégration Elastic ─────
#  L'agent n'est chargé QUE si son fichier existe : un -javaagent vers un JAR
#  absent empêche la JVM de démarrer (« Error opening zip file or JAR
#  manifest missing »). Sans le JAR, vous lirez les métriques JVM avec jcmd
#  et jstat (voie de repli du chapitre), et la collecte Elastic se limitera
#  aux journaux et aux métriques système.
JOLOKIA_JAR="{{JOLOKIA_JAR}}"
if [ -f "$JOLOKIA_JAR" ]; then
  CATALINA_OPTS="$CATALINA_OPTS -javaagent:${JOLOKIA_JAR}=port={{JOLOKIA_PORT}},host=127.0.0.1"
fi

export CATALINA_OPTS
