# Fiche de spécification d'un SLO — {{SERVICE}} ({{STUDENT_ID}})

Une page. Si elle ne tient pas sur une page, le SLO est trop compliqué pour
être tenu.

## 1. Identité

| Rubrique | Valeur |
|---|---|
| Service | {{SERVICE}} |
| Parcours couvert | {{PERIMETRE}} |
| Type de SLI | disponibilité / latence / fraîcheur / exactitude *(rayer)* |
| Objectif (SLO) | {{SLO_PCT}} % |
| Fenêtre | {{FENETRE_JOURS}} jours, glissante |
| Propriétaire | *(une personne nommée, pas une équipe)* |
| Date de la dernière revue | *(à mettre à jour à chaque revue)* |

## 2. Définition de la mesure

| Rubrique | Définition exacte |
|---|---|
| Source de données | {{DATA_STREAM}} |
| Événements **éligibles** (dénominateur) | *(requête complète)* |
| Événements **bons** (numérateur) | *(requête complète)* |
| Point de mesure | frontal / backend / client *(rayer et justifier)* |

## 3. Les cinq décisions, tranchées et justifiées

| Décision | Choix | Justification en une phrase |
|---|---|---|
| Les 4xx comptent-elles comme des échecs ? | | |
| Les sondes de supervision sont-elles dans le dénominateur ? | | |
| Quel est le point de mesure ? | | |
| Que fait-on des événements sans champ de durée ? | | |
| Un échec rapide est-il « bon » pour le SLI de latence ? | | |

## 4. Budget d'erreur

| Rubrique | Valeur mesurée |
|---|---|
| Événements éligibles sur la fenêtre | |
| Budget total (en événements) | |
| Budget consommé (en événements et en %) | |
| Budget restant | |
| Burn rate instantané (1 h) | |

## 5. Fiabilité de la mesure

| Rubrique | Valeur |
|---|---|
| Couverture (part du trafic réellement mesurée) | **…** % |
| Documents en erreur de parsing | *(doit valoir 0)* |
| Limites connues de la mesure | |

## 6. Politique de décision

| Budget restant | Décision |
|---|---|
| > 50 % | Fonctionnement normal : on livre |
| 10 à 50 % | Vigilance : on privilégie les correctifs de fiabilité |
| < 10 % | **Gel des déploiements** de fonctionnalités |
| épuisé | Gel, et revue obligatoire avant reprise |

| Rubrique | Valeur |
|---|---|
| Qui décide du gel ? | |
| Qu'est-ce qui est gelé exactement ? | |
| Comment en sort-on ? | |
