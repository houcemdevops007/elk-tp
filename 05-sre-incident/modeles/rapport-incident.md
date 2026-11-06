# Rapport d'incident — *(titre factuel, sans nom de personne)*

> Modèle en huit sections. Deux pages maximum. Un rapport plus long n'est pas
> lu, donc ne sert à rien.

## 1. Résumé

Trois phrases maximum : ce qui s'est passé, pour qui, pendant combien de temps.

## 2. Impact — entièrement chiffré

| Mesure | Valeur | Méthode de calcul |
|---|---|---|
| Durée de l'incident (début réel → rétablissement) | | |
| Requêtes affectées | | |
| Utilisateurs ou sessions concernés | | |
| Commandes perdues (estimation) | | |
| Budget d'erreur consommé | | |

Aucune formulation qualitative : « beaucoup d'utilisateurs » n'est pas un
impact, c'est une impression.

## 3. Chronologie — à la minute

| Heure (UTC) | Événement |
|---|---|
| | **Début réel** *(reconstitué depuis les données, pas depuis la mémoire)* |
| | Première alerte déclenchée → **MTTD** = … |
| | Prise en charge |
| | Hypothèse 1 formulée / écartée par *(la donnée)* |
| | Hypothèse 2 formulée / écartée par *(la donnée)* |
| | Cause racine identifiée |
| | Correction appliquée |
| | **Rétablissement confirmé par la donnée** → **MTTR** = … |

## 4. Cause racine

Le **mécanisme**, en une phrase, avec sa preuve (requête, capture, métrique).

Puis la question qui compte autant : **pourquoi n'a-t-on pas détecté plus
tôt ?** Elle porte sur le dispositif d'observabilité, pas sur l'incident.

## 5. Ce qui a bien fonctionné

Au moins un élément. Un postmortem qui n'en contient aucun n'est pas un
postmortem, c'est un procès.

## 6. Ce qui a manqué

Données absentes, alertes qui n'ont pas sonné, dashboard trompeur,
procédure introuvable.

## 7. Actions — six minimum, sur trois familles

| Famille | Action | Propriétaire | Date |
|---|---|---|---|
| **Correction** (empêcher la cause de se reproduire) | | | |
| **Correction** | | | |
| **Détection** (voir plus tôt la prochaine fois) | | | |
| **Détection** | | | |
| **Prévention** (réduire l'impact si cela se reproduit) | | | |
| **Prévention** | | | |

Une action sans propriétaire nommé et sans date n'est pas une action :
c'est un vœu.

## 8. Gravité retenue et justification

| Niveau | Justification sur l'impact utilisateur |
|---|---|
| SEV… | |

---

**Règle de rédaction** : ce rapport ne désigne **aucune personne**, même
implicitement. On y parle de mécanismes, de données et de dispositifs. Une
organisation qui cherche un responsable n'apprend rien ; une organisation
qui cherche un mécanisme corrige la cause.
