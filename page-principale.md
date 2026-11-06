# Elastic Observability — manuel de TP condensé

Ce manuel vous fait exploiter une plateforme **Elastic Observability déjà installée** pour superviser une application de bout en bout : un serveur web **Apache**, un backend **Tomcat** sur JVM, puis une application trois tiers sur **Kubernetes**.

Le fil rouge est fictif : la boutique en ligne **ShopFlow**, éditée par la société **NovaCommerce**. Toutes les données, erreurs et pannes de ce manuel concernent cette application de démonstration.

Vous n'administrez pas la plateforme Elastic — vous l'utilisez, comme en entreprise. Ce que vous administrez, c'est **votre VM**, **votre politique d'agent**, **votre namespace** et **vos objets Kibana**.

> **À retenir** — L'observabilité ne consiste pas à « installer un agent ». Elle consiste à pouvoir répondre à une question que l'on ne s'était pas posée à l'avance, avec les données déjà collectées. Les cinq chapitres entraînent cette capacité : collecter, chercher, corréler, alerter, décider.

## Ce que vous saurez faire à la fin

1. Configurer la journalisation d'Apache pour qu'elle soit **exploitable** : format JSON, durée de traitement, exclusion des sondes.
2. Installer et enrôler un Elastic Agent avec la CA interne, et prouver que la donnée arrive.
3. Collecter les journaux d'un serveur d'applications Java, y compris les piles d'appels multilignes.
4. Lire la JVM en quatre indicateurs : heap après GC, temps en GC, threads occupés, sessions.
5. Collecter logs, métriques et événements d'un cluster Kubernetes par DaemonSet.
6. Diagnostiquer les six pannes classiques de Kubernetes en moins de deux minutes chacune.
7. Écrire des requêtes KQL et ES|QL qui répondent à une question d'exploitation.
8. Construire des dashboards dont les taux sont des ratios et les latences des percentiles.
9. Créer des alertes calibrées — et expliquer pourquoi certaines situations ne doivent **pas** alerter.
10. Définir des SLI, des SLO, calculer un error budget et un burn rate.
11. Diagnostiquer un incident dont la nature ne vous a pas été révélée, et le documenter.

## Plan du manuel

| Page | Contenu | Durée |
|---|---|---|
| Introduction | Architecture EFI en détail, rôle de chaque composant, data streams, ECS, ILM, parcours d'une donnée, vérification d'accès | 1 h 30 |
| Chapitre 1 | Logs et métriques Apache HTTP Server, dashboard, 4 alertes, 5 scénarios de panne | 3 h 00 |
| Chapitre 2 | Tomcat : journaux applicatifs, multiligne, JVM, 3 scénarios | 2 h 30 |
| Chapitre 3 | Kubernetes (k3s) : DaemonSet, métriques, 6 pannes à diagnostiquer | 3 h 00 |
| Chapitre 4 | Projet final noté sur 100 : ShopFlow trois tiers, SLO, incident non annoncé | 4 h 00 |
| Chapitre 5 | SRE et gestion d'incident : SLI, SLO, error budget, burn rate, postmortem | 1 h 30 |

**Volume total : environ 14 heures**, soit deux journées de formation. Les chapitres se suivent : chacun suppose acquis le précédent.

## Prérequis

- Savoir se connecter en SSH à une machine Linux et y utiliser `sudo`.
- Manipuler les fichiers en ligne de commande : `cat`, `tail`, `grep`, un éditeur de texte.
- Comprendre les bases de HTTP : méthode, URL, code de réponse, en-têtes.
- Lire du JSON et du YAML.
- Notions de pod, deployment, service et namespace pour les chapitres 3 et 4.
- Un navigateur récent pour accéder à Kibana.

> **Bonne pratique** — Vous n'avez **pas** besoin de savoir développer. Le chapitre 2 lit une classe Java : tout le code nécessaire est fourni et commenté. Il faut seulement accepter de lire un fichier source sans le réécrire.

## Ce que le formateur vous remet

| Élément | Exemple | Où il sert |
|---|---|---|
| Identifiant candidat | `student07` | Suffixe de **tous** vos objets |
| Compte Kibana et espace dédié | `student07` | Vos objets sauvegardés |
| Token d'enrôlement de `efi-studentXX-apache` | secret | Chapitres 1 et 2 — l'agent de votre VM |
| Token d'enrôlement de `efi-studentXX-k8s` | secret | Chapitres 3 et 4 — l'agent en DaemonSet |
| Clé d'API Elasticsearch restreinte | secret | Scripts de vérification |
| Nom d'hôte et IP de votre VM | `vm-student07`, `172.16.20.7` | Les générateurs de configuration |
| Chemin de la CA interne | `/etc/efi/pki/ca.crt` | Enrôlement de l'agent |

> **Attention** — Les tokens d'enrôlement et les clés d'API sont des **secrets**. Ils ne vont jamais dans un canal de discussion, un ticket, un dépôt Git ni une capture d'écran. Les générateurs de ce manuel vous les font saisir localement et ne les enregistrent nulle part.

## Les générateurs de configuration

Chaque chapitre est accompagné d'un **générateur** : une page où vous saisissez les paramètres de votre VM (numéro étudiant, nom d'hôte, IP, chemins, token) et qui produit **vos** fichiers de configuration et **vos** commandes, prêts à copier ou à télécharger.

| Générateur | Ce qu'il produit |
|---|---|
| Chapitre 1 — Apache | Configuration de journalisation, `mod_status`, vhost, rotation, pipeline d'ingestion, 4 règles d'alerte, 5 scripts |
| Chapitre 2 — Tomcat | `setenv.sh`, `AccessLogValve`, JULI, Jolokia, 3 pipelines, application de démonstration, 4 règles, 5 scripts |
| Chapitre 3 — Kubernetes | Namespace et quotas, kube-state-metrics, DaemonSet, application de démonstration, 6 manifestes de panne, 4 règles |
| Chapitre 4 — Projet final | Manifestes des trois tiers, requêtes de SLO, 3 règles, scripts d'incident |
| Chapitre 5 — SRE | Requêtes ES\|QL de SLI, budget et burn rate, règle à double fenêtre, deux modèles de document |

> **Bonne pratique** — Les valeurs fixes de la plateforme (adresses, ports, version de la stack) sont déjà pré-remplies : vous ne saisissez que ce qui vous est propre. Le token, lui, n'est **jamais** pré-rempli.

## Conventions du manuel

| Encadré | Signification |
|---|---|
| **À retenir** | Le point essentiel du passage. À savoir redire avec ses mots |
| **⚠️ Piège fréquent** | Erreur classique, perte de données ou piège de configuration |
| **Bonne pratique** | Ce que l'on fait en production, au-delà du simple « ça marche » |
| **À vérifier sur votre plateforme** | Dépend de la version ou de la licence installée : ne prenez pas la valeur du manuel pour acquise |
| **🔒 Formateur / administrateur** | Opération nécessitant des droits d'administration |
| **✅ Vérification** | Le contrôle à passer avant d'aborder l'étape suivante |

La plateforme est **mutualisée** : vingt candidats travaillent en même temps sur le même cluster. Tout objet que vous créez porte donc votre identifiant.

| Type d'objet | Convention | Exemple |
|---|---|---|
| Data view | `<source>-studentXX` | `apache-student07` |
| Dashboard | `<périmètre>-overview-studentXX` | `apache-overview-student07` |
| Règle d'alerte | `<symptôme>-studentXX` | `taux-5xx-apache-student07` |
| Namespace de data stream | `studentXX` | `student07` |
| Namespace Kubernetes | `studentXX` | `student07` |

> **Attention** — Un TP n'est pas validé par « la commande est passée ». Il est validé par « je peux **montrer la donnée** dans Kibana et **expliquer** ce qu'elle veut dire ». C'est le critère de notation du projet final, et c'est aussi ce qu'on vous demandera en entretien technique.

## Pour commencer

1. Vérifiez votre accès à Kibana et notez votre espace de travail.
2. Relevez la version exacte de la stack et le niveau de licence : vous en aurez besoin dès le chapitre 1.
3. Ouvrez l'**Introduction**, et déroulez ses six vérifications d'accès.
4. Ouvrez le générateur du chapitre 1 et renseignez les paramètres de votre VM.

---

**Khlifi Houcem — Formateur DevSecOps et Cloud** · Plateforme **EFILearn** · Elastic Observability, version condensée.
