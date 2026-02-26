# Tily Cergy Fandresena (EEUdF Cergy)

Site Flask prêt à déployer sur Render + GitHub, avec :
- Pages : Accueil / Nous connaître / Nous soutenir / Actualités / Espace membres
- Auth : inscription / connexion / déconnexion / changement mot de passe
- Rôles : JEUNE (auto-validé), KP/RESPONSABLE (à valider par admin)
- Albums photos : création + upload (staff validé)
- Actualités : mini CMS (admin)
- Dons : lien externe + paiement carte via Stripe Checkout

## Prérequis
- Python 3.12.x

## Lancer en local (Windows PowerShell)
```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
python app.py
```
Ouvre : http://localhost:5000

## Admin initial
Dans `.env` (ou variables Render) :
- INIT_ADMIN_USER=admin
- INIT_ADMIN_PASS=change-me-now

Au premier lancement, l'utilisateur admin est créé automatiquement.

## Déploiement Render
- Connecte le repo GitHub à Render
- Ajoute une base Postgres (ou laisse render.yaml le faire)
- Variables à configurer :
  - SECRET_KEY
  - DATABASE_URL (fourni par Render)
  - BASE_URL (URL Render)
  - STRIPE_SECRET_KEY / STRIPE_PUBLIC_KEY (si paiement activé)
  - DONATION_EXTERNAL_URL (si tu utilises un lien externe)

## Remplacer les logos partenaires
Remplace les fichiers dans `static/img/` :
- tily_france.png
- eeudf.png
- scout_org.png
- fpma_cergy.png
- scout_mg.png

## Notes droit à l'image
Ce projet ajoute une case à cocher obligatoire à l'upload.
Pour les mineurs : autorisation parentale + pas d'identification sans accord.

## Liens partenaires
- Instagram Tily France: https://www.instagram.com/tilyfrance/?hl=fr
- Facebook FPMA Cergy: https://www.facebook.com/p/FPMA-CERGY-61555887332439/
- Tily Madagascar (scout.mg): https://www.scout.mg/
- EEUdF: https://eeudf.org/
- Scout.org: https://www.scout.org/

## Bonus ajoutés
- Bouton **Administration** visible uniquement pour **ADMIN** (navbar)
- Page **Contact** avec formulaire (messages stockés en base et visibles dans /admin)
- Publication d’actus par KP/RESPONSABLE validés : /staff/actus
- Upload images en **production** via **Cloudinary** (optionnel). Si Cloudinary n’est pas configuré, fallback sur stockage local.

### Config Cloudinary (optionnel)
Renseigner dans `.env` ou Render :
- CLOUDINARY_CLOUD_NAME
- CLOUDINARY_API_KEY
- CLOUDINARY_API_SECRET
- CLOUDINARY_FOLDER (optionnel)

## Modération & suppression
- Suppression d’une actu (ADMIN) : bouton "Supprimer" sur /actus ou /admin
- Suppression d’une photo (KP/RESPONSABLE validé) : bouton "Supprimer" dans l’album
- Modération :
  - Albums et photos sont créés **en attente** (approved=false)
  - KP/RESPONSABLE validé (ou ADMIN) peut **Approuver**

## Email (Contact)
Le formulaire Contact enregistre en base ET peut envoyer un email si SMTP est configuré (Render/.env) :
- CONTACT_TO_EMAIL (destinataire)
- SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS
- SMTP_FROM (optionnel)
- SMTP_TLS (true/false)

## PWA (Application mobile)
Le site est une **PWA** : installable comme une application.
Fichiers :
- `static/manifest.json`
- `static/sw.js`
- Icônes : `static/img/icon-192.png` et `static/img/icon-512.png`

### Installer sur Android
Chrome → menu ⋮ → **Ajouter à l’écran d’accueil**

### Installer sur iPhone
Safari → Partager → **Sur l’écran d’accueil**
