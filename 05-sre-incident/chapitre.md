# Chapitre 5 — SRE et gestion d'incident : l'essentiel

| Niveau | Durée estimée | Prérequis |
|---|---|---|
| Intermédiaire | 1 h 30 (dont 45 min d'exercices) | Chapitres 1 à 4. Des données réelles dans vos data streams pour calculer sur vos propres chiffres. |

Les quatre chapitres précédents vous ont appris à **voir**. Celui-ci apprend à **décider** : comment fixer un objectif chiffré, comment savoir si on peut encore se permettre une panne, et comment écrire ce qu'on a appris d'un incident.

C'est volontairement un chapitre court. Il ne remplace pas un cours de SRE : il vous donne les quatre notions dont vous aurez besoin en entretien et en astreinte, et les deux modèles de document à remplir.

## Objectifs

À la fin de ce chapitre, vous savez :

1. Distinguer SLI, SLO et SLA, et dire pourquoi le SLO est plus strict que le SLA.
2. Calculer un error budget et un burn rate à la main, et les lire.
3. Construire une alerte de burn rate à double fenêtre, et dire pourquoi deux fenêtres.
4. Qualifier la gravité d'un incident **sur l'impact utilisateur**.
5. Rédiger un postmortem utile — et éviter celui qui ne sert à rien.

---

## 1. La pyramide des engagements

```text
   ┌──────────────────────────────────────────────────────────┐
   │  SLA  — Service Level AGREEMENT                          │
   │  L'engagement CONTRACTUEL envers un client.              │
   │  Il a des conséquences juridiques et financières.        │
   │  Exemple : 99,5 % de disponibilité, sinon avoir.         │
   ├──────────────────────────────────────────────────────────┤
   │  SLO  — Service Level OBJECTIVE                          │
   │  L'objectif INTERNE que l'équipe se fixe.                │
   │  Toujours PLUS STRICT que le SLA : c'est la marge        │
   │  qui permet de réagir avant de violer le contrat.        │
   │  Exemple : 99,9 % interne pour un SLA à 99,5 %.          │
   ├──────────────────────────────────────────────────────────┤
   │  SLI  — Service Level INDICATOR                          │
   │  La MESURE. Un ratio, toujours :                         │
   │       événements bons / événements éligibles             │
   │  Exemple : requêtes servies en moins de 1 s              │
   │            sur requêtes éligibles.                       │
   └──────────────────────────────────────────────────────────┘
```

| Notion | En une phrase | Qui s'en sert |
|---|---|---|
| **SLI** | Ce que je mesure | L'exploitation, en continu |
| **SLO** | Ce que je m'engage à tenir en interne | L'équipe, pour décider |
| **SLA** | Ce que je dois à un client | Le commerce et le juridique |

> **À retenir** — Le SLO est **toujours** plus strict que le SLA. Si votre contrat promet 99,5 % et que votre objectif interne est 99,5 %, vous découvrirez la violation en même temps que votre client. La marge entre les deux est votre temps de réaction.

Et le SLI est **toujours** un ratio. « Le serveur est up » n'est pas un SLI. « 99,93 % des requêtes du tunnel de commande ont abouti » en est un, parce qu'il a un numérateur et un dénominateur explicites.

### Les quatre familles de SLI

| Famille | Question | Mesure typique |
|---|---|---|
| Disponibilité | Le service répond-il correctement ? | Part des requêtes de code < 500 |
| Latence | Répond-il assez vite ? | Part des requêtes servies sous un seuil |
| Fraîcheur | La donnée est-elle à jour ? | Part des traitements terminés dans le délai |
| Exactitude | La réponse est-elle juste ? | Part des traitements sans anomalie fonctionnelle |

> **⚠️ Piège fréquent** — Pour la latence, on est tenté d'écrire « P95 < 1 s ». Préférez **« 95 % des requêtes servies en moins de 1 s »**. Les deux énoncés semblent équivalents ; ils ne le sont pas. Un percentile ne se **budgète** pas : on ne sait pas dire « il me reste 300 requêtes lentes avant de violer mon P95 ». Un ratio, si — et c'est tout l'intérêt de la suite de ce chapitre.

> **⚠️ Piège fréquent** — Un SLI de latence qui ignore les erreurs **s'améliore quand le service tombe** : une requête qui échoue en 30 ms est très rapide. C'est pourquoi les requêtes du générateur exigent `event.duration < seuil` **et** `status_code < 500`.

---

## 2. L'error budget, en quatre formules

Un objectif de 100 % est intenable et, surtout, il interdit tout changement : la seule façon de ne jamais casser un service est de ne jamais y toucher. Le SLO assume donc une part d'échec — et cette part est un **budget** que l'on peut dépenser.

```text
  ① SLI            = bons / éligibles × 100

  ② budget total   = (100 % − SLO) × éligibles
                     « combien d'échecs j'ai le droit d'avoir »

  ③ budget consommé = mauvais / budget total × 100
                     « quelle part j'ai déjà dépensée »

  ④ burn rate      = (taux d'erreur observé) / (1 − SLO)
                     « à quelle VITESSE je dépense »
```

Le burn rate est la notion la plus utile des quatre, et la moins connue :

| Burn rate | Signification | Le budget de 7 jours part en… |
|---|---|---|
| 1 | Consommation nominale | 7 jours — exactement la fenêtre |
| 2 | Deux fois trop vite | 3 jours et demi |
| 6 | Dégradation sérieuse | 28 heures |
| **14,4** | **Seuil de page classique** | **2 h 20** |
| 100 | Panne franche | 1 h 40 de budget par heure écoulée |

### Un exercice entièrement résolu

> Service `shopflow-web`, parcours `/api/cart` et `/api/commande`.
> SLO de disponibilité : **99,5 % sur 7 jours**.
> Sur la fenêtre : **120 000** requêtes éligibles, dont **890** en code ≥ 500.
> Sur la dernière heure : **1 400** requêtes, dont **180** en erreur.

| Étape | Calcul | Résultat |
|---|---|---|
| SLI | (120 000 − 890) / 120 000 × 100 | **99,258 %** |
| Objectif tenu ? | 99,258 < 99,5 | **non** |
| Budget total | 0,005 × 120 000 | **600** requêtes |
| Budget consommé | 890 / 600 × 100 | **148 %** — dépassé |
| Budget restant | 600 − 890 | **−290** requêtes |
| Taux d'erreur de la dernière heure | 180 / 1 400 | 12,86 % |
| Burn rate instantané | 0,1286 / 0,005 | **25,7** |
| Verdict | Burn rate > 14,4 et budget épuisé | **gel des déploiements, et traitement immédiat** |

> **À retenir** — Le même chiffre dit deux choses différentes selon la fenêtre. Un budget consommé à 148 % dit « on a déjà trop dépensé » — c'est un constat sur le passé. Un burn rate de 25,7 dit « on dépense encore, maintenant, vingt-cinq fois trop vite » — c'est une information sur le **présent**, et c'est elle qui justifie de réveiller quelqu'un.

### Les sept exercices à faire sur vos données

Reprenez chaque question avec les requêtes du générateur, sur **votre** service.

| N° | Question | Où trouver la réponse |
|---|---|---|
| 1 | Calculez votre SLI de disponibilité sur 7 jours | Requête 1 |
| 2 | Votre SLO est-il tenu ? De combien le manquez-vous ? | Requête 1, comparer `sli_pct` à l'objectif |
| 3 | Quel est votre budget total, en requêtes ? | Requête 1, champ `budget_total` |
| 4 | Quelle part du budget avez-vous consommée ? | Requête 1, champ `budget_consomme_pct` |
| 5 | Combien vous reste-t-il ? Est-ce suffisant pour un déploiement risqué ? | Requête 1, champ `budget_restant` |
| 6 | Quel est votre burn rate sur la dernière heure ? Et sur 5 minutes ? | Requêtes 4 et 5 |
| 7 | Quelle part du trafic votre SLI de latence observe-t-il réellement ? | Requête 3, `couverture_pct` |

> **⚠️ Piège fréquent** — L'exercice 7 est celui qu'on saute, et c'est le plus important. Si 20 % des requêtes n'ont pas de champ de durée et que vous les excluez des éligibles, votre SLI de latence porte sur 80 % du trafic — et peut être très loin de la réalité. **Un SLI dont on ne mesure pas la couverture n'est pas fiable.**

### Le coût des « 9 »

| SLO | Indisponibilité autorisée par mois | Par semaine |
|---|---|---|
| 99 % | 7 h 12 | 1 h 41 |
| 99,5 % | 3 h 36 | 50 min |
| 99,9 % | 43 min | 10 min |
| 99,95 % | 21 min | 5 min |
| 99,99 % | 4 min 20 | 1 min |

> **À retenir** — Chaque « 9 » supplémentaire coûte environ **dix fois** plus cher : redondance, automatisation, astreinte, tests. La bonne question n'est jamais « peut-on faire 99,99 % ? » mais « **qu'est-ce que le client gagne entre 99,9 % et 99,99 %, et combien cela coûte-t-il ?** ». Un service interne de reporting n'a pas besoin du même objectif qu'un tunnel de paiement.

### Décider avec le budget

| Budget restant | Décision |
|---|---|
| > 50 % | Fonctionnement normal : on livre des fonctionnalités |
| 10 à 50 % | Vigilance : on privilégie les correctifs de fiabilité |
| < 10 % | **Gel des déploiements** de fonctionnalités |
| épuisé | Gel, et revue obligatoire avant reprise |

Cette politique doit être écrite **avant** d'en avoir besoin, et répondre à trois questions : qui décide du gel, ce qui est gelé exactement (les fonctionnalités, pas les correctifs de sécurité), et comment on en sort.

---

## 3. L'alerte de burn rate, à double fenêtre

C'est la seule alerte de ce manuel qui justifie de réveiller quelqu'un la nuit.

```text
  FENÊTRE LONGUE (1 heure)   burn rate > 14,4
     -> prouve que le problème est SIGNIFICATIF
        (une fenêtre courte seule déclencherait sur un micro-incident)

                    ET

  FENÊTRE COURTE (5 minutes) burn rate > 14,4
     -> prouve que le problème est TOUJOURS EN COURS
        (une fenêtre longue seule réveillerait pour un incident terminé)
```

| Seuils usuels | Fenêtres | Réaction |
|---|---|---|
| 14,4 | 1 h et 5 min | Page immédiate : 2 % du budget en 1 heure |
| 6 | 6 h et 30 min | Page : 5 % du budget en 6 heures |
| 1 | 3 j et 6 h | Ticket : consommation lente mais insoutenable |

> **⚠️ À vérifier sur votre plateforme** — Les règles de burn rate **natives** de Kibana relèvent d'une licence commerciale. La voie de repli est fournie et donne exactement les mêmes chiffres : la règle « fenêtre longue » écrit dans un index d'alertes via le connecteur **Index** (gratuit), et la règle « fenêtre courte » lit cet index en plus de sa propre condition. <!-- À VÉRIFIER : disponibilité des SLO natifs et du connecteur souhaité selon la licence réellement installée sur la plateforme EFI. -->

---

## 4. Qualifier un incident

```text
  SEV1  Service indisponible OU parcours critique bloqué pour la majorité
        -> réaction immédiate 24/7, communication externe
        -> ShopFlow : paiement impossible, site inaccessible

  SEV2  Dégradation forte OU parcours critique dégradé
        -> immédiate en heures ouvrées, astreinte si heure de pointe
        -> ShopFlow : panier à 8 s, 15 % des commandes en échec

  SEV3  Dégradation limitée, contournement possible
        -> jour ouvré suivant
        -> ShopFlow : recherche lente, images manquantes

  SEV4  Anomalie sans impact utilisateur
        -> backlog
        -> ShopFlow : log d'erreur bénin, métrique manquante
```

> **⚠️ Piège fréquent** — Qualifier la gravité d'après la **complexité technique** plutôt que d'après l'**impact utilisateur**. Un bug très sophistiqué qui n'affecte personne est un SEV4. Un espace disque plein qui bloque les commandes est un SEV1. L'échelle se décide à l'avance, et elle ne parle que d'impact.

### Les quatre temps d'un incident

| Temps | Ce qu'on fait | L'erreur classique |
|---|---|---|
| **Détection** | Noter l'heure de prise de connaissance, qualifier la gravité | Commencer à diagnostiquer sans noter l'heure |
| **Atténuation** | Rétablir le service, même sans comprendre | Chercher la cause avant de rétablir |
| **Diagnostic** | Métriques, puis logs, puis corrélation entre tiers | Changer trois réglages à la fois |
| **Clôture** | Valider le rétablissement **par la donnée**, puis écrire | Déclarer la fin sur une impression |

> **À retenir** — Atténuer avant de comprendre n'est pas de la négligence, c'est la bonne pratique : un redémarrage qui rétablit le service vous donne le temps de diagnostiquer calmement. La faute serait de ne **pas** diagnostiquer ensuite. Et toute action d'atténuation doit être **consignée** : c'est souvent elle qui efface la preuve dont vous aurez besoin.

### Deux chiffres à savoir calculer

| Mesure | Définition | Ce qu'elle dit |
|---|---|---|
| **MTTD** | début **réel** → première détection | La qualité de votre dispositif d'alerte |
| **MTTR** | début réel → rétablissement confirmé | La qualité de votre réponse |

Le **début réel** se reconstitue dans les données, jamais de mémoire. C'est tout l'intérêt d'avoir centralisé : vous pouvez remonter avant l'alerte et trouver la première minute anormale.

> **⚠️ Piège fréquent** — Reconstituer la chronologie **après** l'incident donne systématiquement un récit plus rationnel que la réalité : les hypothèses fausses disparaissent, les vingt minutes perdues sur une mauvaise piste s'évaporent. Et c'est précisément cette information qui est utile. Tenez le journal **pendant**, deux lignes par hypothèse, avec l'heure.

---

## 5. Le postmortem

Deux pages, huit sections — le modèle `rapport-incident.md` du générateur est prêt à remplir.

| Section | Le point à ne pas rater |
|---|---|
| 1. Résumé | Trois phrases : quoi, pour qui, combien de temps |
| 2. Impact | **Entièrement chiffré** : « beaucoup d'utilisateurs » n'est pas un impact |
| 3. Chronologie | À la minute, avec le **début réel**, le MTTD et le MTTR |
| 4. Cause racine | Le **mécanisme**, en une phrase, **avec sa preuve** — plus la question « pourquoi non détecté plus tôt ? » |
| 5. Ce qui a bien fonctionné | Au moins un élément |
| 6. Ce qui a manqué | Données absentes, alerte muette, dashboard trompeur |
| 7. Actions | **Six minimum**, sur trois familles, chacune avec propriétaire et date |
| 8. Gravité retenue | Justifiée sur l'impact |

Les trois familles d'actions, et pourquoi les trois sont obligatoires :

| Famille | Question | Exemple ShopFlow |
|---|---|---|
| **Correction** | Comment empêcher la cause ? | Aligner la limite mémoire du conteneur sur la heap de la JVM |
| **Détection** | Comment voir plus tôt ? | Ajouter l'alerte de burn rate à double fenêtre |
| **Prévention** | Comment réduire l'impact si cela se reproduit ? | Ajouter une `startupProbe`, limiter la taille de la réponse du panier |

> **À retenir** — Un postmortem qui ne contient que des actions de **correction** laisse le dispositif de détection inchangé : la prochaine panne, différente, sera découverte aussi tard. Les équipes qui progressent sont celles qui, à chaque incident, ajoutent **une** règle d'alerte ou **un** panneau de dashboard.

> **⚠️ Piège fréquent** — Le postmortem « sans blâme » est souvent mal comprise : il ne s'agit pas d'être gentil, il s'agit d'être **efficace**. Une organisation qui cherche un responsable apprend que les gens cachent les incidents. Une organisation qui cherche un mécanisme corrige la cause. Concrètement : le rapport ne désigne **aucune personne**, même implicitement, et il contient au moins un élément qui a bien fonctionné.

### La question qui clôt un incident

> « Notre dispositif aurait-il détecté cet incident **avant** qu'un client n'appelle ? »

Et la preuve : le délai de détection **mesuré**. C'est la seule question qui compte, et c'est celle qu'on vous posera en entretien technique.

---

## Livrables du chapitre

1. La fiche de spécification d'**un** de vos SLO, remplie, avec les cinq décisions tranchées et justifiées.
2. Les résultats des sept exercices, calculés sur **vos** données, avec les requêtes utilisées.
3. Votre burn rate instantané et sa lecture en une phrase.
4. La **couverture** de votre SLI de latence, et ce que vous en concluez sur sa fiabilité.
5. La règle d'alerte de burn rate à double fenêtre, avec ses deux délais mesurés.
6. Le rapport d'incident du chapitre 4, rédigé selon le modèle en huit sections.
7. Votre politique de gel des déploiements : seuils, qui décide, ce qui est gelé, comment on en sort.

---

**Fin du manuel.** Vous savez collecter, chercher, corréler, alerter et décider. Ce qui reste à acquérir ne s'apprend pas dans un support : c'est l'habitude de regarder la donnée **avant** d'avoir une opinion.

**Khlifi Houcem — Formateur DevSecOps et Cloud** · Plateforme **EFILearn** · Elastic Observability, version condensée.
