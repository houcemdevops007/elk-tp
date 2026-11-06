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
CATALINA_OPTS="$CATALINA_OPTS -XX:+ExitOnOutOfMemoryError"

# ─── JMX, pour la collecte de métriques JVM et Tomcat ───────────────────────
#  N'EXPOSEZ JAMAIS JMX SANS AUTHENTIFICATION SUR UNE INTERFACE PUBLIQUE :
#  JMX non authentifié permet l'exécution de code à distance. La
#  configuration ci-dessous n'est acceptable QUE parce qu'elle est restreinte
#  à 127.0.0.1 et que le collecteur tourne sur la machine elle-même.
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.port={{JMX_PORT}}"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.rmi.port={{JMX_PORT}}"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.local.only=true"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.authenticate=false"
CATALINA_OPTS="$CATALINA_OPTS -Dcom.sun.management.jmxremote.ssl=false"
CATALINA_OPTS="$CATALINA_OPTS -Djava.rmi.server.hostname=127.0.0.1"

# ─── Agent Jolokia : expose JMX en HTTP/JSON pour l'intégration Elastic ─────
#  Le fichier jolokia-jvm-agent.jar est fourni par le formateur et déposé
#  dans {{JOLOKIA_JAR}}. Si vous ne l'avez pas, commentez la ligne : vous
#  lirez alors les métriques JVM avec jcmd et jstat (voie de repli du
#  chapitre), et la collecte Elastic se limitera aux journaux.
CATALINA_OPTS="$CATALINA_OPTS -javaagent:{{JOLOKIA_JAR}}=port={{JOLOKIA_PORT}},host=127.0.0.1"

export CATALINA_OPTS
