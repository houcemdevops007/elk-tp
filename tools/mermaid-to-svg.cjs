/*
 * mermaid-to-svg.cjs — rend les blocs ```mermaid des pages en SVG statique.
 *
 * POURQUOI : le frontend d'EFIlearn ne charge pas Mermaid. Un bloc ```mermaid
 * s'afficherait donc en code source. Un SVG, lui, s'affiche nativement dans
 * l'éditeur, sur la page publique et dans les exports HTML/PDF, sans aucun
 * JavaScript.
 *
 * Le Markdown reste la source de vérité : le SVG est un artefact de
 * construction, déposé à côté de la page sous le nom
 * <page>.mermaid-<n>.svg, et repris automatiquement par le script de
 * publication (qui retombe sur le bloc de code si le SVG est absent).
 *
 * Prérequis, une seule fois :  npm install mermaid playwright
 * Usage :  node tools/mermaid-to-svg.cjs 00-introduction.md 04-projet-final/enonce.md
 */
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const mermaidJs = require.resolve("mermaid/dist/mermaid.min.js");

(async () => {
  const fichiers = process.argv.slice(2);
  if (!fichiers.length) {
    console.error("usage : node tools/mermaid-to-svg.cjs <page.md> [...]");
    process.exit(1);
  }
  const nav = await chromium.launch();
  const page = await nav.newPage();
  await page.setContent("<!doctype html><body><div id='c'></div></body>");
  await page.addScriptTag({ path: mermaidJs });
  await page.evaluate(() => window.mermaid.initialize({
    startOnLoad: false,
    theme: "base",
    securityLevel: "strict",
    themeVariables: {
      fontFamily: "system-ui, -apple-system, Segoe UI, Roboto, sans-serif",
      fontSize: "14px",
      primaryColor: "#eef2ff",
      primaryTextColor: "#1b1f24",
      primaryBorderColor: "#6366f1",
      lineColor: "#64748b",
      tertiaryColor: "#f8fafc",
      clusterBkg: "#f8fafc",
      clusterBorder: "#cbd5e1",
    },
  }));

  let total = 0;
  for (const fichier of fichiers) {
    const source = fs.readFileSync(fichier, "utf8");
    const blocs = [...source.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1]);
    for (let i = 0; i < blocs.length; i++) {
      const svg = await page.evaluate(async (code) => {
        const { svg } = await window.mermaid.render("d" + Date.now(), code);
        return svg;
      }, blocs[i]);
      const cible = `${fichier.replace(/\.md$/, "")}.mermaid-${i + 1}.svg`;
      // Largeur fluide : le diagramme suit la colonne de texte sans déborder.
      fs.writeFileSync(cible, svg.replace(/<svg /, '<svg style="max-width:100%;height:auto" '));
      console.log(`[OK] ${path.basename(cible)}  (${Math.round(svg.length / 1024)} Ko)`);
      total++;
    }
  }
  await nav.close();
  console.log(`${total} diagramme(s) rendu(s).`);
})();
