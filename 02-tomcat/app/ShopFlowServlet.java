/*
 * ShopFlowServlet.java — application de démonstration ShopFlow (NovaCommerce).
 *
 * Société fictive, boutique fictive, aucune donnée réelle, aucun appel réseau
 * vers l'extérieur. Candidat : {{STUDENT_ID}}
 *
 * Routes exposées (préfixe du contexte : /{{APP_CONTEXT}}) :
 *   GET /health              sonde de supervision (à exclure des mesures)
 *   GET /api/cart            panier ; ?scenario=degrade rend la requête lente et lourde
 *   GET /api/produit         fiche produit
 *   GET /api/lent?ms=N       réponse temporisée de N millisecondes (max 30 000)
 *   GET /api/erreur?type=X   npe | sql | 500
 *   GET /api/fuite?mo=N      retient N Mo NON LIBÉRÉS (fuite mémoire volontaire)
 *   GET /api/reset           libère la mémoire retenue et désactive le mode dégradé
 *   GET /api/db              état du troisième tier : disponibilité et latence
 *                            de PostgreSQL (chapitre 4)
 *   GET /api/commande        parcours complet : vérifie la base puis « enregistre »
 *                            une commande ; 503 si la base est injoignable
 *
 * Compilation : voir build-war.sh (javac + jar, sans Maven ni réseau).
 */
package com.novacommerce.shopflow;

import java.io.IOException;
import java.io.PrintWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = {"/health", "/api/*"})
public class ShopFlowServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    /* Collection STATIQUE : support de la fuite mémoire volontaire.
     * Dans du vrai code, c'est exactement l'erreur à ne pas commettre —
     * un cache sans politique d'éviction ne libère jamais rien. */
    private static final List<byte[]> RETENU = new ArrayList<>();

    private static final Random RND = new Random(42);   // graine fixe : reproductible
    private static volatile boolean MODE_DEGRADE = false;

    /* Journalisation applicative en JSON ECS : exploitable sans aucun parsing.
     * service.name doit être IDENTIQUE à celui posé sur les logs Apache,
     * sinon la corrélation entre les deux sources est impossible. */
    private static void log(String niveau, String message) {
        System.out.println("{\"@timestamp\":\"" + Instant.now()
            + "\",\"log.level\":\"" + niveau
            + "\",\"service.name\":\"shopflow-api\""
            + ",\"service.version\":\"2.4.1\""
            + ",\"service.environment\":\"{{STUDENT_ID}}\""
            + ",\"process.thread.name\":\"" + Thread.currentThread().getName() + "\""
            + ",\"message\":\"" + message.replace("\"", "'") + "\"}");
    }

    private static void repondre(HttpServletResponse rep, int code, String corps)
            throws IOException {
        rep.setStatus(code);
        rep.setContentType("application/json; charset=utf-8");
        try (PrintWriter out = rep.getWriter()) {
            out.print(corps);
        }
    }

    private static int entier(HttpServletRequest req, String nom, int defaut, int max) {
        String v = req.getParameter(nom);
        if (v == null) {
            return defaut;
        }
        try {
            return Math.min(Integer.parseInt(v), max);
        } catch (NumberFormatException e) {
            return defaut;
        }
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse rep)
            throws ServletException, IOException {

        String chemin = req.getServletPath();
        if ("/api".equals(chemin) && req.getPathInfo() != null) {
            chemin = "/api" + req.getPathInfo();
        } else if (req.getPathInfo() != null) {
            chemin = chemin + req.getPathInfo();
        }

        /* Identifiant de corrélation injecté par Apache : le pont entre les
         * logs du reverse proxy et ceux du backend. */
        String requestId = req.getHeader("X-Request-Id");
        if (requestId != null) {
            rep.setHeader("X-Request-Id", requestId);
        }

        try {
            if (chemin.equals("/health")) {
                repondre(rep, 200,
                    "{\"status\":\"UP\",\"service\":\"shopflow-api\",\"student\":\"{{STUDENT_ID}}\"}");

            } else if (chemin.startsWith("/api/cart")) {
                panier(req, rep);

            } else if (chemin.startsWith("/api/produit")) {
                dormir(10 + RND.nextInt(30));
                repondre(rep, 200, "{\"sku\":\"SKU-123456\",\"prix\":1990}");

            } else if (chemin.startsWith("/api/lent")) {
                int ms = entier(req, "ms", 1000, 30000);
                dormir(ms);
                repondre(rep, 200, "{\"attendu_ms\":" + ms + "}");

            } else if (chemin.startsWith("/api/erreur")) {
                erreur(req, rep);

            } else if (chemin.startsWith("/api/fuite")) {
                int mo = entier(req, "mo", 10, 200);
                for (int i = 0; i < mo; i++) {
                    RETENU.add(new byte[1024 * 1024]);
                }
                log("WARN", "memoire retenue volontairement: " + RETENU.size() + " Mo");
                repondre(rep, 200, "{\"retenu_mo\":" + RETENU.size() + "}");

            } else if (chemin.startsWith("/api/db")) {
                etatBase(rep);

            } else if (chemin.startsWith("/api/commande")) {
                commande(rep);

            } else if (chemin.startsWith("/api/reset")) {
                int avant = RETENU.size();
                RETENU.clear();
                MODE_DEGRADE = false;
                log("INFO", "reset: " + avant + " Mo liberes, mode degrade desactive");
                repondre(rep, 200, "{\"libere_mo\":" + avant + "}");

            } else {
                repondre(rep, 404, "{\"erreur\":\"route inconnue\"}");
            }
        } catch (RuntimeException e) {
            /* Imprime une VRAIE pile d'appels multiligne sur stdout :
             * c'est la matière du traitement multiligne du chapitre. */
            e.printStackTrace();
            log("ERROR", e.getClass().getName() + ": " + e.getMessage());
            repondre(rep, 500, "{\"erreur\":\"" + e.getClass().getSimpleName() + "\"}");
        }
    }

    /* Le panier : cœur du fil rouge. En mode dégradé, la requête n'est pas
     * bornée : elle charge 142 000 articles, met ~4 s et renvoie ~180 Ko.
     * Code de retour 200 : INVISIBLE pour une supervision par code de statut. */
    private void panier(HttpServletRequest req, HttpServletResponse rep) throws IOException {
        String scenario = req.getParameter("scenario");
        if ("degrade".equals(scenario)) {
            MODE_DEGRADE = true;
        } else if ("normal".equals(scenario)) {
            MODE_DEGRADE = false;
        }

        int articles = MODE_DEGRADE ? 142000 : 3;
        dormir(MODE_DEGRADE ? 3800 + RND.nextInt(600) : 25 + RND.nextInt(40));

        StringBuilder sb = new StringBuilder("{\"articles\":").append(articles).append(",\"items\":[");
        int aEcrire = Math.min(articles, MODE_DEGRADE ? 2000 : 3);
        for (int i = 0; i < aEcrire; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append("{\"sku\":\"SKU-").append(100000 + i).append("\",\"qte\":1}");
        }
        sb.append("]}");

        if (MODE_DEGRADE) {
            log("WARN", "chargement du panier anormalement long: " + articles + " articles");
        }
        repondre(rep, 200, sb.toString());
    }

    private void erreur(HttpServletRequest req, HttpServletResponse rep) throws IOException {
        String type = req.getParameter("type");
        if (type == null) {
            type = "500";
        }
        switch (type) {
            case "npe":
                log("ERROR", "chargement du panier impossible");
                String nul = null;
                nul.length();                                  // NullPointerException
                break;
            case "sql":
                log("WARN", "HikariPool-1 - Connection is not available,"
                    + " request timed out after 30000ms");
                throw new IllegalStateException(
                    "java.sql.SQLTimeoutException: Timeout after 30000ms"
                    + " of waiting for connection");
            default:
                log("ERROR", "erreur applicative simulee");
                repondre(rep, 500, "{\"erreur\":\"erreur interne simulee\"}");
        }
    }

    /* ── Troisième tier : PostgreSQL (chapitre 4) ───────────────────────────
     * Le pilote JDBC n'est pas disponible hors ligne sur la plateforme de TP.
     * On mesure donc la disponibilité et la latence d'ÉTABLISSEMENT DE
     * CONNEXION TCP vers la base, ce qui suffit à observer les trois tiers et
     * à reproduire les incidents du projet. L'emplacement d'une vraie requête
     * SQL est indiqué en commentaire : en production, on mesurerait la durée
     * d'un « SELECT 1 » avec un pool de connexions.
     *
     * Variables d'environnement attendues : DB_HOST, DB_PORT (ConfigMap),
     * DB_USER et DB_PASSWORD (Secret) — ces deux dernières ne sont pas
     * utilisées ici, mais elles sont injectées pour montrer le bon usage
     * d'un Secret. */
    private static long latenceBase() throws IOException {
        String hote = System.getenv().getOrDefault("DB_HOST", "127.0.0.1");
        int port = Integer.parseInt(System.getenv().getOrDefault("DB_PORT", "5432"));
        long debut = System.nanoTime();
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(hote, port), 2000);
            // Emplacement d'un « SELECT 1 » avec un vrai pilote JDBC.
            return (System.nanoTime() - debut) / 1000000L;
        }
    }

    private void etatBase(HttpServletResponse rep) throws IOException {
        try {
            long ms = latenceBase();
            if (ms > 500) {
                log("WARN", "base de donnees lente: " + ms + " ms");
            }
            repondre(rep, 200, "{\"db\":\"up\",\"latence_ms\":" + ms + "}");
        } catch (IOException e) {
            /* La base est injoignable : on renvoie 503 (et non 500). 503 dit
             * « dépendance indisponible », ce qui oriente immédiatement le
             * diagnostic vers le tier suivant au lieu de l'application. */
            log("ERROR", "base de donnees injoignable: " + e.getMessage());
            repondre(rep, 503, "{\"db\":\"down\",\"erreur\":\"connexion impossible\"}");
        }
    }

    private void commande(HttpServletResponse rep) throws IOException {
        try {
            long ms = latenceBase();
            dormir(20 + RND.nextInt(40));
            log("INFO", "commande enregistree, base a " + ms + " ms");
            repondre(rep, 201, "{\"commande\":\"CMD-" + (100000 + RND.nextInt(899999))
                + "\",\"db_latence_ms\":" + ms + "}");
        } catch (IOException e) {
            log("ERROR", "commande refusee: base de donnees injoignable");
            repondre(rep, 503, "{\"erreur\":\"base indisponible\"}");
        }
    }

    private static void dormir(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    }
}
