# Grille d'évaluation — Projet final ShopFlow

Document **formateur**. À communiquer aux candidats **avant** le projet : une grille connue à l'avance oriente le travail vers ce qui compte, au lieu de récompenser ceux qui devinent les attentes.

| Repère | Signification |
|---|---|
| **Éliminatoire** | Si le critère n'est pas rempli, les points de la ligne tombent à 0, quelle que soit la qualité du reste |
| *Preuve* | Ce que le candidat doit montrer. Une affirmation sans preuve vaut 0 |

## Partie 1 — Déploiement et collecte (25 points)

| N° | Critère | Points | Preuve attendue |
|---|---|---|---|
| 1.1 | Les trois tiers sont déployés et le parcours complet répond (`/api/commande` → 201) | 4 | Sortie de `kubectl get pods,svc,pvc` + les quatre `curl` de vérification |
| 1.2 | Logs du **tier 1** collectés, JSON décodé, `event.duration` présent **et en nanosecondes** | 5 | Document JSON dans Discover. **Éliminatoire** : 0 si l'unité est fausse, car dashboards, SLO et alertes sont alors tous faux |
| 1.3 | Logs du **tier 2** collectés, exceptions Java en **un seul** document | 4 | Capture d'une exception complète dans un document |
| 1.4 | Logs du **tier 3** collectés, et intégration PostgreSQL active | 4 | Documents de logs PostgreSQL + jeu de données de métriques |
| 1.5 | Métriques Kubernetes des trois tiers, dont `state_container` | 3 | `last_terminated_reason` visible dans Discover |
| 1.6 | Identifiants de la base dans un **Secret**, jamais en annotation ni en clair | 3 | Manifeste + explication du compromis si des hints sont utilisés |
| 1.7 | Contrôle qualité : **zéro** `error.message`, couverture de la durée > 99 % | 2 | Les deux requêtes de comptage et leurs résultats |

## Partie 2 — Dashboard de bout en bout (20 points)

| N° | Critère | Points | Preuve attendue |
|---|---|---|---|
| 2.1 | Les taux sont des **ratios** en pourcentage, hors trafic de supervision | 5 | Les formules Lens recopiées |
| 2.2 | Percentiles corrects, affichés en millisecondes, segmentés par route | 4 | Formule + capture |
| 2.3 | Les erreurs sont décomposées **par tier** | 4 | Panneau avec la dimension composant |
| 2.4 | Tableau de diagnostic des pods à six colonnes, avec mise en forme conditionnelle | 3 | Capture |
| 2.5 | Panneau Markdown : objectif, sources, **limites connues** | 2 | Capture. 1 point si les limites manquent |
| 2.6 | Chemin agrégat → détail en trois clics, décrit et fonctionnel | 2 | Description du chemin |

## Partie 3 — SLO et budget d'erreur (20 points)

| N° | Critère | Points | Preuve attendue |
|---|---|---|---|
| 3.1 | Trois fiches de SLO : éligibles et bons définis en requête | 6 | Les trois fiches |
| 3.2 | Les **cinq décisions** tranchées **et justifiées** | 5 | Une justification par décision. 0 si les décisions sont seulement énoncées |
| 3.3 | Budget d'erreur : total, consommé, restant, en requêtes **et** en pourcentage | 4 | Résultat des requêtes |
| 3.4 | **Couverture** du SLI de latence mesurée et commentée | 3 | Requête de couverture + commentaire |
| 3.5 | SLI jour par jour, avec lecture de la répartition de la consommation | 2 | Résultat + une phrase d'analyse |

## Partie 4 — Alerting (15 points)

| N° | Critère | Points | Preuve attendue |
|---|---|---|---|
| 4.1 | Seuils **calibrés sur l'historique mesuré** (min / médiane / max) | 4 | Tableau de calibrage. 0 si les seuils sont recopiés du tutoriel |
| 4.2 | Burn rate à **double fenêtre**, les deux conditions exigées | 3 | Définition des deux règles + explication du « ET » |
| 4.3 | Alerte d'absence de données **testée par coupure réelle** | 3 | **Éliminatoire** : 0 si non testée |
| 4.4 | Garde-fous : volume minimal, regroupement, action de rétablissement | 3 | Définitions des règles |
| 4.5 | Délais de détection **et** d'extinction mesurés pour chaque règle | 2 | Tableau des délais |

## Partie 5 — Incident non annoncé (15 points)

| N° | Critère | Points | Preuve attendue |
|---|---|---|---|
| 5.1 | Chronologie datée, avec **début réel** reconstitué et MTTD calculé | 3 | Journal d'investigation tenu en temps réel |
| 5.2 | Hypothèses écartées **par la donnée**, et non par intuition | 4 | Une ligne par hypothèse, avec la donnée qui l'a écartée |
| 5.3 | Cause racine en une phrase, avec sa **preuve** | 4 | La phrase + la capture ou la requête qui la prouve |
| 5.4 | Impact chiffré : requêtes, commandes, budget consommé | 2 | Les trois chiffres et leur méthode de calcul |
| 5.5 | Correction traitant la **cause** et non le symptôme, validée par la donnée | 2 | Avant / après, chiffré |

## Partie 6 — Rapport et synthèse (5 points)

| N° | Critère | Points |
|---|---|---|
| 6.1 | Rapport complet, impact entièrement chiffré | 2 |
| 6.2 | Au moins six actions, couvrant correction, détection **et** prévention, avec propriétaire et date | 2 |
| 6.3 | Rédaction sans désignation de personne, synthèse compréhensible sans jargon | 1 |

## Bonus (jusqu'à 5 points, sans dépasser 100)

| Bonus | Points |
|---|---|
| Pipeline de masquage d'une donnée sensible, démontré avant / après | +2 |
| Plan de capacité chiffré, avec une date de saturation estimée | +2 |
| Une amélioration non demandée, pertinente et argumentée | +1 |

## Barème de lecture

| Note | Interprétation |
|---|---|
| 90 – 100 | Prêt pour une astreinte : la chaîne est juste, mesurée, documentée, et le candidat sait ce qu'il ne voit pas |
| 75 – 89 | Solide. Quelques décisions non assumées ou un contrôle qualité manquant |
| 60 – 74 | Fonctionnel mais fragile : souvent des seuils non calibrés et une couverture non mesurée |
| 40 – 59 | La collecte marche, l'interprétation manque. Le candidat montre des écrans, pas des conclusions |
| < 40 | Erreur d'unité, trafic de supervision compté, ou alerte d'absence de données non testée |

> **Note au formateur** — Les trois erreurs qui reviennent le plus souvent, et qui méritent d'être corrigées collectivement : l'unité du champ de durée (facteur 1 000 entre Apache et Tomcat), les sondes de supervision laissées dans le dénominateur, et une alerte d'absence de données jamais testée. Ces trois erreurs produisent des dashboards qui **fonctionnent** tout en étant faux — ce qui est plus dangereux qu'une absence de dashboard.
