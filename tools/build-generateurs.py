#!/usr/bin/env python3
"""Construit les generateurs HTML autonomes des chapitres.

Source de verite unique : les fichiers de configuration des chapitres
(configs/, manifests/, scripts/, alertes/, app/, requetes/) sont lus TELS QUELS
et injectes dans le gabarit tools/generateur.tpl.html. Un generateur ne peut
donc jamais divergir du fichier publie dans le chapitre.

Usage :
    python3 tools/build-generateurs.py            # construit tous les chapitres
    python3 tools/build-generateurs.py 01-apache  # un seul chapitre
"""
import json
import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
GABARIT = RACINE / "tools" / "generateur.tpl.html"
PLATEFORME = json.loads((RACINE / "tools" / "plateforme.json").read_text(encoding="utf-8"))

EXT_LANG = {
    ".yaml": "yaml", ".yml": "yaml", ".json": "json", ".sh": "bash", ".conf": "apache",
    ".xml": "xml", ".properties": "properties", ".java": "java", ".esql": "sql",
    ".sql": "sql", ".env": "bash", ".md": "text", ".txt": "text",
}


def lang_de(nom, explicite=None):
    return explicite or EXT_LANG.get(Path(nom).suffix, "text")


def charge_entree(chapitre, entree):
    """Resout une entree 'files' ou 'commands' : contenu inline ou fichier du depot."""
    sortie = dict(entree)
    if "from" in entree:
        src = chapitre / entree["from"]
        if not src.is_file():
            raise SystemExit(f"[ERREUR] fichier absent : {src}")
        sortie["content"] = src.read_text(encoding="utf-8")
        sortie.setdefault("name", src.name)
        sortie.pop("from", None)
    if "content" not in sortie:
        raise SystemExit(f"[ERREUR] entree sans 'from' ni 'content' dans {chapitre.name}")
    sortie["lang"] = lang_de(sortie["name"], entree.get("lang"))
    return sortie


def construit(chapitre):
    spec = json.loads((chapitre / "generateur.json").read_text(encoding="utf-8"))

    constants = []
    for cle in spec.get("constants", []):
        if isinstance(cle, str):
            if cle not in PLATEFORME["constants"]:
                raise SystemExit(f"[ERREUR] constante inconnue : {cle}")
            constants.append(PLATEFORME["constants"][cle])
        else:
            constants.append(cle)

    charge = {
        "chapitre": spec["chapitre"],
        "intro": spec.get("intro", ""),
        "constants": constants,
        "fixed": dict(PLATEFORME["fixed"], **spec.get("fixed", {})),
        "fields": spec["fields"],
        "derived": spec.get("derived", {}),
        "recap": spec.get("recap", []),
        "commands": [charge_entree(chapitre, e) for e in spec.get("commands", [])],
        "files": [charge_entree(chapitre, e) for e in spec.get("files", [])],
    }

    gabarit = GABARIT.read_text(encoding="utf-8")
    html = (gabarit
            .replace("__TITRE__", spec["chapitre"])
            .replace("__PAYLOAD__", json.dumps(charge, ensure_ascii=False, indent=1)))
    cible = chapitre / "generateur.html"
    cible.write_text(html, encoding="utf-8")
    print(f"[OK] {cible.relative_to(RACINE)} "
          f"({len(html) // 1024} Ko, {len(charge['files'])} fichiers, "
          f"{len(charge['commands'])} blocs de commandes)")


def main():
    demandes = sys.argv[1:]
    chapitres = sorted(p.parent for p in RACINE.glob("*/generateur.json"))
    if demandes:
        chapitres = [c for c in chapitres if c.name in demandes]
        if not chapitres:
            raise SystemExit(f"[ERREUR] aucun chapitre parmi {demandes}")
    for c in chapitres:
        construit(c)


if __name__ == "__main__":
    main()
