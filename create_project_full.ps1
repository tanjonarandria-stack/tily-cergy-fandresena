Param([string]$ProjectName = "tily-cergy-fandresena")
$ErrorActionPreference="Stop"
$root = Join-Path (Get-Location) $ProjectName
Write-Host "Création du projet dans: $root"
$dirs=@("","templates","static","static\css","static\img","static\uploads","instance")
foreach($d in $dirs){ New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
function Write-File($rel,$content){ $path=Join-Path $root $rel; $dir=Split-Path $path -Parent; if(!(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}; Set-Content -Path $path -Value $content -Encoding UTF8 }
Write-File ".env.example" @"
# Copy this file to .env and fill values
SECRET_KEY=change-me
DATABASE_URL=sqlite:///instance/app.db
BASE_URL=http://localhost:5000

# Optional: create initial admin on first run
INIT_ADMIN_USER=admin
INIT_ADMIN_PASS=change-me-now

# Donations
DONATION_EXTERNAL_URL=
STRIPE_SECRET_KEY=
STRIPE_PUBLIC_KEY=

"@
Write-File ".gitignore" @"
__pycache__/
*.pyc
.venv/
env/
instance/
static/uploads/
.DS_Store
.env
*.sqlite3

"@
Write-File "Procfile" @"
web: gunicorn app:create_app()

"@
Write-File "README.md" @"
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

"@
Write-File "app.py" @"
import os
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from werkzeug.utils import secure_filename
import stripe

from config import Config
from models import db, User, NewsPost, Album, Photo

ALLOWED_EXTENSIONS = {""png"", ""jpg"", ""jpeg"", ""webp""}

def allowed_file(filename: str) -> bool:
    return ""."" in filename and filename.rsplit(""."", 1)[1].lower() in ALLOWED_EXTENSIONS

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    os.makedirs(app.config[""UPLOAD_FOLDER""], exist_ok=True)
    os.makedirs(""instance"", exist_ok=True)

    db.init_app(app)

    login_manager = LoginManager()
    login_manager.login_view = ""login""
    login_manager.init_app(app)

    stripe.api_key = app.config[""STRIPE_SECRET_KEY""]

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    with app.app_context():
        db.create_all()

        # Create initial admin user if env vars are set
        admin_user = os.getenv(""INIT_ADMIN_USER"")
        admin_pass = os.getenv(""INIT_ADMIN_PASS"")
        if admin_user and admin_pass and not User.query.filter_by(username=admin_user.lower()).first():
            u = User(username=admin_user.lower(), role=""ADMIN"", role_validated=True)
            u.set_password(admin_pass)
            db.session.add(u)
            db.session.commit()

    # ---------------- PUBLIC ----------------
    @app.route(""/"")
    def home():
        latest = NewsPost.query.order_by(NewsPost.created_at.desc()).limit(3).all()
        return render_template(""home.html"", latest=latest)

    @app.route(""/nous-connaitre"")
    def nous_connaitre():
        return render_template(""nous_connaitre.html"")

    @app.route(""/actus"")
    def actus():
        posts = NewsPost.query.order_by(NewsPost.created_at.desc()).all()
        return render_template(""actus.html"", posts=posts)

    @app.route(""/nous-soutenir"")
    def nous_soutenir():
        return render_template(
            ""nous_soutenir.html"",
            stripe_public_key=app.config[""STRIPE_PUBLIC_KEY""],
            external_url=app.config[""DONATION_EXTERNAL_URL""],
        )

    # ---------------- AUTH ----------------
    @app.route(""/membres"")
    def membres():
        return render_template(""membres.html"")

    @app.route(""/register"", methods=[""GET"", ""POST""])
    def register():
        if request.method == ""POST"":
            username = request.form.get(""username"", """").strip().lower()
            password = request.form.get(""password"", """")
            role_choice = request.form.get(""role"", ""JEUNE"")

            if not username or not password:
                flash(""Merci de remplir tous les champs."", ""error"")
                return redirect(url_for(""register""))

            if len(password) < 8:
                flash(""Mot de passe trop court (8 caractères minimum)."", ""error"")
                return redirect(url_for(""register""))

            if User.query.filter_by(username=username).first():
                flash(""Ce login existe déjà."", ""error"")
                return redirect(url_for(""register""))

            user = User(username=username)

            # Sécurité: JEUNE validé automatiquement.
            if role_choice == ""JEUNE"":
                user.role = ""JEUNE""
                user.role_validated = True
            else:
                # KP/RESPONSABLE: demande à valider par admin
                user.role = ""JEUNE""
                user.role_requested = role_choice
                user.role_validated = False

            user.set_password(password)
            db.session.add(user)
            db.session.commit()

            flash(""Compte créé. Si tu as demandé un rôle KP/RESPONSABLE, il doit être validé par un admin."", ""success"")
            return redirect(url_for(""login""))

        return render_template(""register.html"")

    @app.route(""/login"", methods=[""GET"", ""POST""])
    def login():
        if request.method == ""POST"":
            username = request.form.get(""username"", """").strip().lower()
            password = request.form.get(""password"", """")

            user = User.query.filter_by(username=username).first()
            if not user or not user.check_password(password):
                flash(""Login ou mot de passe incorrect."", ""error"")
                return redirect(url_for(""login""))

            login_user(user)
            flash(""Connecté ✅"", ""success"")
            return redirect(url_for(""member_area""))

        return render_template(""login.html"")

    @app.route(""/logout"")
    @login_required
    def logout():
        logout_user()
        flash(""Déconnecté."", ""success"")
        return redirect(url_for(""home""))

    @app.route(""/changer-mot-de-passe"", methods=[""GET"", ""POST""])
    @login_required
    def change_password():
        if request.method == ""POST"":
            old = request.form.get(""old_password"", """")
            new = request.form.get(""new_password"", """")

            if not current_user.check_password(old):
                flash(""Ancien mot de passe incorrect."", ""error"")
                return redirect(url_for(""change_password""))

            if len(new) < 8:
                flash(""Nouveau mot de passe trop court (8 caractères minimum)."", ""error"")
                return redirect(url_for(""change_password""))

            current_user.set_password(new)
            db.session.commit()
            flash(""Mot de passe mis à jour ✅"", ""success"")
            return redirect(url_for(""member_area""))

        return render_template(""change_password.html"")

    # ---------------- MEMBER AREA ----------------
    @app.route(""/espace"")
    @login_required
    def member_area():
        albums = Album.query.order_by(Album.created_at.desc()).all()
        return render_template(""album_list.html"", albums=albums)

    @app.route(""/album/nouveau"", methods=[""GET"", ""POST""])
    @login_required
    def album_new():
        if not current_user.is_staff():
            flash(""Accès réservé (KP/RESPONSABLE validé)."", ""error"")
            return redirect(url_for(""member_area""))

        if request.method == ""POST"":
            title = request.form.get(""title"", """").strip()
            desc = request.form.get(""description"", """").strip()
            consent = request.form.get(""consent"", """")

            if consent != ""yes"":
                flash(""Merci de confirmer le respect du droit à l’image."", ""error"")
                return redirect(url_for(""album_new""))

            if not title:
                flash(""Titre obligatoire."", ""error"")
                return redirect(url_for(""album_new""))

            a = Album(title=title, description=desc)
            db.session.add(a)
            db.session.commit()
            flash(""Album créé ✅"", ""success"")
            return redirect(url_for(""album_view"", album_id=a.id))

        return render_template(""album_new.html"")

    @app.route(""/album/<int:album_id>"", methods=[""GET"", ""POST""])
    @login_required
    def album_view(album_id):
        album = db.session.get(Album, album_id)
        if not album:
            flash(""Album introuvable."", ""error"")
            return redirect(url_for(""member_area""))

        if request.method == ""POST"":
            if not current_user.is_staff():
                flash(""Upload réservé (KP/RESPONSABLE validé)."", ""error"")
                return redirect(url_for(""album_view"", album_id=album_id))

            file = request.files.get(""photo"")
            caption = request.form.get(""caption"", """").strip()
            consent = request.form.get(""consent"", """")

            if consent != ""yes"":
                flash(""Merci de confirmer le respect du droit à l’image."", ""error"")
                return redirect(url_for(""album_view"", album_id=album_id))

            if not file or file.filename == """":
                flash(""Aucun fichier sélectionné."", ""error"")
                return redirect(url_for(""album_view"", album_id=album_id))

            if not allowed_file(file.filename):
                flash(""Format non autorisé (png/jpg/jpeg/webp)."", ""error"")
                return redirect(url_for(""album_view"", album_id=album_id))

            filename = secure_filename(file.filename)
            save_path = os.path.join(app.config[""UPLOAD_FOLDER""], filename)

            # Avoid overwriting
            i = 1
            base, ext = os.path.splitext(filename)
            while os.path.exists(save_path):
                filename = f""{base}-{i}{ext}""
                save_path = os.path.join(app.config[""UPLOAD_FOLDER""], filename)
                i += 1

            file.save(save_path)
            p = Photo(album_id=album_id, file_path=f""/{app.config['UPLOAD_FOLDER']}/{filename}"", caption=caption)
            db.session.add(p)
            db.session.commit()

            flash(""Photo ajoutée ✅"", ""success"")
            return redirect(url_for(""album_view"", album_id=album_id))

        photos = Photo.query.filter_by(album_id=album_id).order_by(Photo.created_at.desc()).all()
        return render_template(""album_view.html"", album=album, photos=photos)

    # ---------------- ADMIN ----------------
    @app.route(""/admin"", methods=[""GET"", ""POST""])
    @login_required
    def admin_dashboard():
        if current_user.role != ""ADMIN"":
            flash(""Accès admin uniquement."", ""error"")
            return redirect(url_for(""home""))

        pending = User.query.filter(User.role_requested != """", User.role_validated == False).all()
        posts = NewsPost.query.order_by(NewsPost.created_at.desc()).limit(20).all()

        if request.method == ""POST"":
            action = request.form.get(""action"", """")

            if action == ""validate_role"":
                user_id = int(request.form.get(""user_id""))
                u = db.session.get(User, user_id)
                if u and u.role_requested in (""KP"", ""RESPONSABLE""):
                    u.role = u.role_requested
                    u.role_requested = """"
                    u.role_validated = True
                    db.session.commit()
                    flash(""Rôle validé ✅"", ""success"")

            elif action == ""new_post"":
                title = request.form.get(""title"", """").strip()
                content = request.form.get(""content"", """").strip()
                file = request.files.get(""image"")

                if not title or not content:
                    flash(""Titre + contenu obligatoires."", ""error"")
                    return redirect(url_for(""admin_dashboard""))

                image_path = """"
                if file and file.filename and allowed_file(file.filename):
                    fname = secure_filename(file.filename)
                    path = os.path.join(app.config[""UPLOAD_FOLDER""], fname)

                    # Avoid overwriting
                    i = 1
                    base, ext = os.path.splitext(fname)
                    while os.path.exists(path):
                        fname = f""{base}-{i}{ext}""
                        path = os.path.join(app.config[""UPLOAD_FOLDER""], fname)
                        i += 1

                    file.save(path)
                    image_path = f""/{app.config['UPLOAD_FOLDER']}/{fname}""

                post = NewsPost(title=title, content=content, image_path=image_path)
                db.session.add(post)
                db.session.commit()
                flash(""Actu publiée ✅"", ""success"")

        return render_template(""admin_dashboard.html"", pending=pending, posts=posts)

    # ---------------- STRIPE DONATION ----------------
    @app.route(""/don/checkout"", methods=[""POST""])
    def donation_checkout():
        try:
            amount_eur = int(request.form.get(""amount_eur"", ""10""))
        except ValueError:
            amount_eur = 10
        amount_eur = max(1, min(amount_eur, 5000))  # 1€ à 5000€

        if not app.config[""STRIPE_SECRET_KEY""]:
            flash(""Stripe n’est pas configuré (STRIPE_SECRET_KEY)."", ""error"")
            return redirect(url_for(""nous_soutenir""))

        session = stripe.checkout.Session.create(
            mode=""payment"",
            payment_method_types=[""card""],
            line_items=[{
                ""price_data"": {
                    ""currency"": ""eur"",
                    ""product_data"": {""name"": ""Don – Tily Cergy Fandresena (EEUdF Cergy)""},
                    ""unit_amount"": amount_eur * 100,
                },
                ""quantity"": 1,
            }],
            success_url=f""{app.config['BASE_URL']}{url_for('don_success')}"",
            cancel_url=f""{app.config['BASE_URL']}{url_for('nous_soutenir')}"",
        )
        return redirect(session.url, code=303)

    @app.route(""/don/merci"")
    def don_success():
        return render_template(""don_success.html"")

    return app

if __name__ == ""__main__"":
    app = create_app()
    app.run(debug=True)

"@
Write-File "config.py" @"
import os

class Config:
    SECRET_KEY = os.getenv(""SECRET_KEY"", ""dev-secret-change-me"")
    # Render sometimes provides postgres:// -> SQLAlchemy expects postgresql://
    SQLALCHEMY_DATABASE_URI = os.getenv(""DATABASE_URL"", ""sqlite:///instance/app.db"").replace(""postgres://"", ""postgresql://"")
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    UPLOAD_FOLDER = os.getenv(""UPLOAD_FOLDER"", ""static/uploads"")
    MAX_CONTENT_LENGTH = 10 * 1024 * 1024  # 10MB

    STRIPE_SECRET_KEY = os.getenv(""STRIPE_SECRET_KEY"", """")
    STRIPE_PUBLIC_KEY = os.getenv(""STRIPE_PUBLIC_KEY"", """")
    DONATION_EXTERNAL_URL = os.getenv(""DONATION_EXTERNAL_URL"", """")
    BASE_URL = os.getenv(""BASE_URL"", ""http://localhost:5000"")

"@
Write-File "models.py" @"
from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

db = SQLAlchemy()

class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)

    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)

    # Final roles: JEUNE / RESPONSABLE / KP / ADMIN
    role = db.Column(db.String(20), default=""JEUNE"", nullable=False)
    # If the user requested KP/RESPONSABLE at signup -> admin validates
    role_requested = db.Column(db.String(20), default="""", nullable=False)
    role_validated = db.Column(db.Boolean, default=False, nullable=False)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, raw_password: str):
        self.password_hash = generate_password_hash(raw_password)

    def check_password(self, raw_password: str) -> bool:
        return check_password_hash(self.password_hash, raw_password)

    def is_staff(self) -> bool:
        return (self.role in (""KP"", ""RESPONSABLE"", ""ADMIN"")) and bool(self.role_validated)

class NewsPost(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(140), nullable=False)
    content = db.Column(db.Text, nullable=False)
    image_path = db.Column(db.String(255), default="""")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class Album(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(140), nullable=False)
    description = db.Column(db.Text, default="""")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class Photo(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    album_id = db.Column(db.Integer, db.ForeignKey(""album.id""), nullable=False)
    file_path = db.Column(db.String(255), nullable=False)
    caption = db.Column(db.String(200), default="""")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

"@
Write-File "render.yaml" @"
services:
  - type: web
    name: tily-cergy-fandresena
    runtime: python
    plan: free
    buildCommand: pip install -r requirements.txt
    startCommand: gunicorn app:create_app()
    envVars:
      - key: PYTHON_VERSION
        value: 3.12.2
      - key: SECRET_KEY
        generateValue: true
      - key: BASE_URL
        value: https://YOUR-RENDER-URL.onrender.com
      - key: DONATION_EXTERNAL_URL
        value: """"
      - key: STRIPE_SECRET_KEY
        value: """"
      - key: STRIPE_PUBLIC_KEY
        value: """"
      - key: INIT_ADMIN_USER
        value: admin
      - key: INIT_ADMIN_PASS
        value: change-me-now
databases:
  - name: tily-cergy-db
    plan: free

"@
Write-File "requirements.txt" @"
Flask==3.0.0
Flask-Login==0.6.3
Flask-SQLAlchemy==3.1.1
Werkzeug==3.0.1
python-dotenv==1.0.1
gunicorn==22.0.0
stripe==10.12.0

"@
Write-File "runtime.txt" @"
python-3.12.2

"@
Write-File "static/css/style.css" @"
:root{
  --bg:#0b1020;
  --card:#111a33;
  --text:#eaf0ff;
  --muted:#b9c3e6;
  --accent:#7cf0c7;
  --accent2:#9bb6ff;
  --danger:#ff6b6b;
  --border:rgba(255,255,255,.12);
  --shadow: 0 12px 40px rgba(0,0,0,.35);
  --radius:18px;
  --max:1100px;
}

*{box-sizing:border-box}
body{
  margin:0;
  font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial;
  background: radial-gradient(1200px 700px at 15% 10%, rgba(124,240,199,.18), transparent 55%),
              radial-gradient(900px 600px at 85% 0%, rgba(155,182,255,.18), transparent 55%),
              var(--bg);
  color:var(--text);
}

a{color:inherit; text-decoration:none}
.container{max-width:var(--max); margin:0 auto; padding: 26px 16px;}
.row{display:flex; gap:14px; align-items:center}
.row-between{display:flex; gap:14px; align-items:flex-start; justify-content:space-between; flex-wrap:wrap}
.nav{display:flex; gap:12px; align-items:center; flex-wrap:wrap}

.topbar{
  position:sticky; top:0;
  backdrop-filter: blur(10px);
  background: rgba(11,16,32,.65);
  border-bottom:1px solid var(--border);
  z-index:20;
}
.topbar .container{padding:14px 16px}

.brand{display:flex; gap:12px; align-items:center}
.brand-mark{
  width:40px; height:40px; display:grid; place-items:center;
  background: linear-gradient(135deg, rgba(124,240,199,.25), rgba(155,182,255,.25));
  border:1px solid var(--border);
  border-radius:14px;
  box-shadow: var(--shadow);
}
.brand-text{font-weight:800}
.brand-sub{margin-left:10px; color:var(--muted); font-size:12px}

.nav a{padding:10px 12px; border-radius: 12px; color: var(--muted);}
.nav a:hover{background:rgba(255,255,255,.06); color:var(--text)}

.pill{
  padding:10px 12px;
  border-radius:999px;
  border:1px solid var(--border);
  background:rgba(255,255,255,.04);
}
.pill.danger{border-color: rgba(255,107,107,.35); color: #ffd5d5}
.pill:hover{background:rgba(255,255,255,.07)}

.hero{display:grid; grid-template-columns: 1.1fr .9fr; gap:18px;}
.hero-card{
  background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.03));
  border:1px solid var(--border);
  border-radius: var(--radius);
  padding: 22px;
  box-shadow: var(--shadow);
}

h1{font-size:42px; margin:0 0 10px}
h2{margin:0 0 10px}
h3{margin:0 0 8px}

.lead{color:var(--muted); font-size:16px; line-height:1.55}
.accent{color:var(--accent)}
.cta{display:flex; gap:12px; flex-wrap:wrap; margin-top:14px}

.btn{
  display:inline-block;
  padding: 12px 14px;
  border-radius: 14px;
  border:1px solid rgba(124,240,199,.30);
  background: rgba(124,240,199,.14);
  font-weight:700;
}
.btn:hover{transform: translateY(-1px); background: rgba(124,240,199,.18)}
.btn.secondary{border-color: rgba(155,182,255,.32); background: rgba(155,182,255,.12);}
.btn.secondary:hover{background: rgba(155,182,255,.16)}
.btn:disabled{opacity:.5; cursor:not-allowed}

.link{color:var(--accent2)}
.link:hover{text-decoration:underline}

.grid-3{display:grid; grid-template-columns: repeat(3, 1fr); gap:14px; margin-top:18px}
.grid-2{display:grid; grid-template-columns: repeat(2, 1fr); gap:14px}
.panel{background: rgba(255,255,255,.04); border:1px solid var(--border); border-radius: var(--radius); padding: 18px;}

.cards{list-style:none; padding:0; margin:0; display:grid; gap:12px}
.cards-grid{display:grid; grid-template-columns: repeat(2, 1fr); gap:14px}
.card{background: rgba(255,255,255,.04); border:1px solid var(--border); border-radius: var(--radius); overflow:hidden;}
.link-card:hover{transform: translateY(-1px); background: rgba(255,255,255,.06)}
.card-body{padding:16px}
.card-title{margin:0 0 6px}
.card-img{width:100%; height:220px; object-fit:cover; display:block; border-bottom:1px solid var(--border)}

.flash{margin: 0 0 14px; display:grid; gap:10px}
.flash-item{padding: 12px 14px; border-radius: 14px; border:1px solid var(--border); background: rgba(255,255,255,.04);}
.flash-item.success{border-color: rgba(124,240,199,.35)}
.flash-item.error{border-color: rgba(255,107,107,.35)}

.form{display:grid; gap:10px; max-width: 520px;}
label{color:var(--muted); font-weight:650}
input, textarea, select{
  padding: 12px 12px;
  border-radius: 14px;
  border:1px solid var(--border);
  background: rgba(0,0,0,.18);
  color: var(--text);
  outline:none;
}
input:focus, textarea:focus, select:focus{border-color: rgba(155,182,255,.5)}
.checkbox{display:flex; gap:10px; align-items:flex-start}
.checkbox input{margin-top:4px}

.photos{display:grid; grid-template-columns: repeat(3, 1fr); gap:12px; margin-top:14px}
.photo{margin:0; background: rgba(255,255,255,.04); border:1px solid var(--border); border-radius: 16px; overflow:hidden;}
.photo img{width:100%; height:220px; object-fit:cover; display:block}
.photo figcaption{padding:10px 12px; color:var(--muted); font-size:13px}

.list{list-style:none; padding:0; margin:0; display:grid; gap:10px}
.list-item{display:flex; align-items:center; justify-content:space-between; gap:12px; padding: 12px; border-radius: 14px; border:1px solid var(--border); background: rgba(0,0,0,.12);}

.footer{margin-top: 26px; border-top:1px solid var(--border); background: rgba(0,0,0,.25);}
.footer .container{padding: 22px 16px}
.footer-grid{display:grid; grid-template-columns: 1.2fr .8fr; gap:16px}
.partners{display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin: 10px 0 0}
.partners img{width:44px; height:44px; object-fit:contain; border-radius: 12px; border:1px solid var(--border); background: rgba(255,255,255,.04); padding:6px;}
.muted{color:var(--muted)}
.callout{margin-top: 14px; padding: 16px; border-radius: var(--radius); border:1px solid rgba(124,240,199,.25); background: rgba(124,240,199,.08);}

@media (max-width: 980px){
  .hero{grid-template-columns: 1fr}
  .grid-3{grid-template-columns:1fr}
  .grid-2{grid-template-columns:1fr}
  .cards-grid{grid-template-columns:1fr}
  .photos{grid-template-columns:1fr 1fr}
  h1{font-size:34px}
}
@media (max-width: 520px){
  .photos{grid-template-columns:1fr}
}

"@
Write-File "static/img/eeudf.png" @"
PLACEHOLDER - replace with real image file

"@
Write-File "static/img/fpma_cergy.png" @"
PLACEHOLDER - replace with real image file

"@
Write-File "static/img/scout_mg.png" @"
PLACEHOLDER - replace with real image file

"@
Write-File "static/img/scout_org.png" @"
PLACEHOLDER - replace with real image file

"@
Write-File "static/img/tily_france.png" @"
PLACEHOLDER - replace with real image file

"@
Write-File "templates/actus.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Actualités</h1>

{% if posts %}
  <div class=""cards-grid"">
    {% for post in posts %}
      <article class=""card"">
        {% if post.image_path %}
          <img class=""card-img"" src=""{{ post.image_path }}"" alt=""Image actu"">
        {% endif %}
        <div class=""card-body"">
          <h2 class=""card-title"">{{ post.title }}</h2>
          <p class=""muted"">{{ post.created_at.strftime(""%d/%m/%Y"") }}</p>
          <p>{{ post.content }}</p>
        </div>
      </article>
    {% endfor %}
  </div>
{% else %}
  <p class=""muted"">Aucune actualité pour le moment.</p>
{% endif %}

{% if current_user.is_authenticated and current_user.role == ""ADMIN"" %}
  <p><a class=""btn"" href=""{{ url_for('admin_dashboard') }}"">Aller à l’admin</a></p>
{% endif %}
{% endblock %}

"@
Write-File "templates/admin_dashboard.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Admin</h1>

<div class=""grid-2"">
  <div class=""panel"">
    <h2>Valider les rôles (KP/RESPONSABLE)</h2>
    {% if pending %}
      <ul class=""list"">
        {% for u in pending %}
          <li class=""list-item"">
            <div>
              <strong>{{ u.username }}</strong>
              <span class=""muted"">a demandé: {{ u.role_requested }}</span>
            </div>
            <form method=""post"">
              <input type=""hidden"" name=""action"" value=""validate_role"">
              <input type=""hidden"" name=""user_id"" value=""{{ u.id }}"">
              <button class=""btn"" type=""submit"">Valider</button>
            </form>
          </li>
        {% endfor %}
      </ul>
    {% else %}
      <p class=""muted"">Aucune demande en attente.</p>
    {% endif %}
  </div>

  <div class=""panel"">
    <h2>Publier une actu</h2>
    <form method=""post"" enctype=""multipart/form-data"" class=""form"">
      <input type=""hidden"" name=""action"" value=""new_post"">
      <label>Titre</label>
      <input name=""title"" required>

      <label>Contenu</label>
      <textarea name=""content"" rows=""6"" required placeholder=""Texte de l'événement, infos pratiques, etc.""></textarea>

      <label>Flyer / image (optionnel)</label>
      <input type=""file"" name=""image"" accept="".png,.jpg,.jpeg,.webp"">

      <button class=""btn"" type=""submit"">Publier</button>
    </form>
  </div>
</div>

<h2>Dernières actus</h2>
{% if posts %}
  <div class=""cards-grid"">
    {% for post in posts %}
      <article class=""card"">
        <div class=""card-body"">
          <h3>{{ post.title }}</h3>
          <p class=""muted"">{{ post.created_at.strftime(""%d/%m/%Y"") }}</p>
          <p>{{ post.content[:200] }}{% if post.content|length > 200 %}…{% endif %}</p>
        </div>
      </article>
    {% endfor %}
  </div>
{% else %}
  <p class=""muted"">Aucune actu.</p>
{% endif %}
{% endblock %}

"@
Write-File "templates/album_list.html" @"
{% extends ""base.html"" %}
{% block content %}
<div class=""row-between"">
  <div>
    <h1>Albums</h1>
    <p class=""muted"">Bienvenue {{ current_user.username }} — rôle: {{ current_user.role }}{% if not current_user.role_validated %} (en attente){% endif %}</p>
  </div>
  <div class=""row"">
    <a class=""btn secondary"" href=""{{ url_for('change_password') }}"">Changer mot de passe</a>
    {% if current_user.role == ""ADMIN"" %}
      <a class=""btn"" href=""{{ url_for('admin_dashboard') }}"">Admin</a>
    {% endif %}
    {% if current_user.is_staff() %}
      <a class=""btn"" href=""{{ url_for('album_new') }}"">Nouvel album</a>
    {% endif %}
  </div>
</div>

{% if albums %}
  <div class=""cards-grid"">
    {% for a in albums %}
      <a class=""card link-card"" href=""{{ url_for('album_view', album_id=a.id) }}"">
        <div class=""card-body"">
          <h2 class=""card-title"">{{ a.title }}</h2>
          <p class=""muted"">{{ a.created_at.strftime(""%d/%m/%Y"") }}</p>
          <p>{{ a.description[:140] }}{% if a.description|length > 140 %}…{% endif %}</p>
        </div>
      </a>
    {% endfor %}
  </div>
{% else %}
  <p class=""muted"">Aucun album pour le moment.</p>
{% endif %}
{% endblock %}

"@
Write-File "templates/album_new.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Créer un album</h1>

<form method=""post"" class=""form"">
  <label>Titre</label>
  <input name=""title"" required>

  <label>Description</label>
  <textarea name=""description"" rows=""4"" placeholder=""Ex: Week-end de groupe, activité service, camp...""></textarea>

  <label class=""checkbox"">
    <input type=""checkbox"" name=""consent"" value=""yes"" required>
    Je confirme respecter le droit à l’image (autorisation parentale pour mineurs, pas de photos sensibles).
  </label>

  <button class=""btn"" type=""submit"">Créer</button>
</form>
{% endblock %}

"@
Write-File "templates/album_view.html" @"
{% extends ""base.html"" %}
{% block content %}
<div class=""row-between"">
  <div>
    <h1>{{ album.title }}</h1>
    <p class=""muted"">{{ album.created_at.strftime(""%d/%m/%Y"") }} — {{ album.description }}</p>
  </div>
  <div class=""row"">
    <a class=""btn secondary"" href=""{{ url_for('member_area') }}"">← Retour</a>
  </div>
</div>

{% if current_user.is_staff() %}
  <div class=""panel"">
    <h2>Ajouter une photo</h2>
    <form method=""post"" enctype=""multipart/form-data"" class=""form"">
      <label>Photo (png/jpg/jpeg/webp)</label>
      <input type=""file"" name=""photo"" accept="".png,.jpg,.jpeg,.webp"" required>

      <label>Légende (optionnel)</label>
      <input name=""caption"" placeholder=""Ex: Jeu de piste, veillée, service..."">

      <label class=""checkbox"">
        <input type=""checkbox"" name=""consent"" value=""yes"" required>
        Je confirme respecter le droit à l’image (autorisation parentale pour mineurs, pas de photos sensibles).
      </label>

      <button class=""btn"" type=""submit"">Uploader</button>
    </form>
  </div>
{% endif %}

{% if photos %}
  <div class=""photos"">
    {% for p in photos %}
      <figure class=""photo"">
        <img src=""{{ p.file_path }}"" alt=""Photo"">
        {% if p.caption %}<figcaption>{{ p.caption }}</figcaption>{% endif %}
      </figure>
    {% endfor %}
  </div>
{% else %}
  <p class=""muted"">Aucune photo pour le moment.</p>
{% endif %}
{% endblock %}

"@
Write-File "templates/base.html" @"
<!doctype html>
<html lang=""fr"">
<head>
  <meta charset=""utf-8"" />
  <meta name=""viewport"" content=""width=device-width, initial-scale=1"" />
  <title>{{ title or ""Tily Cergy Fandresena – EEUdF Cergy"" }}</title>
  <meta name=""description"" content=""Tily Cergy Fandresena (EEUdF Cergy) – Scoutisme, foi chrétienne, service et fraternité."" />
  <link rel=""stylesheet"" href=""{{ url_for('static', filename='css/style.css') }}"">
</head>
<body>
  <header class=""topbar"">
    <div class=""container row"">
      <a class=""brand"" href=""{{ url_for('home') }}"">
        <span class=""brand-mark"">⛺</span>
        <span class=""brand-text"">Tily Cergy <strong>Fandresena</strong></span>
        <span class=""brand-sub"">EEUdF Cergy</span>
      </a>

      <nav class=""nav"">
        <a href=""{{ url_for('nous_connaitre') }}"">Nous connaître</a>
        <a href=""{{ url_for('nous_soutenir') }}"">Nous soutenir</a>
        <a href=""{{ url_for('actus') }}"">Actualités</a>
        <a href=""{{ url_for('membres') }}"">Espace membres</a>
        {% if current_user.is_authenticated %}
          <a class=""pill"" href=""{{ url_for('member_area') }}"">Mon espace</a>
          <a class=""pill danger"" href=""{{ url_for('logout') }}"">Déconnexion</a>
        {% else %}
          <a class=""pill"" href=""{{ url_for('login') }}"">Connexion</a>
        {% endif %}
      </nav>
    </div>
  </header>

  <main class=""container"">
    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        <div class=""flash"">
          {% for cat, msg in messages %}
            <div class=""flash-item {{ cat }}"">{{ msg }}</div>
          {% endfor %}
        </div>
      {% endif %}
    {% endwith %}

    {% block content %}{% endblock %}
  </main>

  <footer class=""footer"">
    <div class=""container"">
      <div class=""footer-grid"">
        <div>
          <h4>Partenaires & liens</h4>
          <div class=""partners"">
            <!-- Remplace les href par tes vrais liens -->
            <a href=""#"" target=""_blank"" rel=""noopener"" title=""Instagram Tily France"">
              <img src=""{{ url_for('static', filename='img/tily_france.png') }}"" alt=""Tily France"">
            </a>
            <a href=""https://eeudf.org/"" target=""_blank"" rel=""noopener"" title=""EEUdF"">
              <img src=""{{ url_for('static', filename='img/eeudf.png') }}"" alt=""EEUdF"">
            </a>
            <a href=""https://www.scout.org/"" target=""_blank"" rel=""noopener"" title=""WOSM"">
              <img src=""{{ url_for('static', filename='img/scout_org.png') }}"" alt=""scout.org"">
            </a>
            <a href=""#"" target=""_blank"" rel=""noopener"" title=""Facebook FPMA Cergy"">
              <img src=""{{ url_for('static', filename='img/fpma_cergy.png') }}"" alt=""FPMA Cergy"">
            </a>
            <a href=""#"" target=""_blank"" rel=""noopener"" title=""Tily eto Madagasikara"">
              <img src=""{{ url_for('static', filename='img/scout_mg.png') }}"" alt=""scout.mg"">
            </a>
          </div>
          <p class=""muted"">⚠️ Photos : respecter le droit à l’image, surtout pour les mineurs (autorisation parentale).</p>
        </div>

        <div>
          <h4>Contact</h4>
          <p class=""muted"">Tu peux remplacer ce bloc par une adresse email, un téléphone, ou un formulaire.</p>
          <p class=""muted"">© {{ 2026 }} — Tily Cergy Fandresena (EEUdF Cergy)</p>
        </div>
      </div>
    </div>
  </footer>
</body>
</html>

"@
Write-File "templates/change_password.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Modifier mon mot de passe</h1>

<form method=""post"" class=""form"">
  <label>Ancien mot de passe</label>
  <input name=""old_password"" type=""password"" autocomplete=""current-password"" required>

  <label>Nouveau mot de passe (8 caractères minimum)</label>
  <input name=""new_password"" type=""password"" autocomplete=""new-password"" required minlength=""8"">

  <button class=""btn"" type=""submit"">Mettre à jour</button>
</form>
{% endblock %}

"@
Write-File "templates/don_success.html" @"
{% extends ""base.html"" %}
{% block content %}
<div class=""callout"">
  <h1>Merci ! 🙏</h1>
  <p>Ton don a bien été pris en compte. Merci de soutenir les activités de Tily Cergy Fandresena.</p>
  <p><a class=""btn"" href=""{{ url_for('home') }}"">Retour à l’accueil</a></p>
</div>
{% endblock %}

"@
Write-File "templates/home.html" @"
{% extends ""base.html"" %}
{% block content %}
<section class=""hero"">
  <div class=""hero-card"">
    <h1>Tily Cergy <span class=""accent"">Fandresena</span></h1>
    <p class=""lead"">
      Un groupe scout (EEUdF Cergy) : grandir, servir, vivre la fraternité — enraciné dans la foi chrétienne.
    </p>
    <div class=""cta"">
      <a class=""btn"" href=""{{ url_for('nous_connaitre') }}"">Nous connaître</a>
      <a class=""btn secondary"" href=""{{ url_for('nous_soutenir') }}"">Nous soutenir</a>
    </div>
  </div>

  <div class=""hero-card"">
    <h2>Dernières actualités</h2>
    {% if latest %}
      <ul class=""cards"">
        {% for post in latest %}
          <li class=""card"">
            <div class=""card-body"">
              <h3>{{ post.title }}</h3>
              <p class=""muted"">{{ post.created_at.strftime(""%d/%m/%Y"") }}</p>
              <p>{{ post.content[:180] }}{% if post.content|length > 180 %}…{% endif %}</p>
            </div>
          </li>
        {% endfor %}
      </ul>
      <a class=""link"" href=""{{ url_for('actus') }}"">Voir toutes les actualités →</a>
    {% else %}
      <p class=""muted"">Aucune actu pour le moment. (Les KP/Admin pourront publier depuis l’admin.)</p>
    {% endif %}
  </div>
</section>

<section class=""grid-3"">
  <div class=""panel"">
    <h3>Scoutisme & valeurs</h3>
    <p>Une aventure concrète : activités, camps, services, responsabilité, esprit d’équipe.</p>
  </div>
  <div class=""panel"">
    <h3>Une histoire récente</h3>
    <p>Créé en 2024 à Cergy, d’abord section vivante FPMA Cergy, puis intégration EEUdF en 2025.</p>
  </div>
  <div class=""panel"">
    <h3>Transparence</h3>
    <p>Les dons aident à rendre les activités accessibles (matériel, camps, transports, formations).</p>
  </div>
</section>
{% endblock %}

"@
Write-File "templates/login.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Connexion</h1>

<form method=""post"" class=""form"">
  <label>Login</label>
  <input name=""username"" autocomplete=""username"" required>

  <label>Mot de passe</label>
  <input name=""password"" type=""password"" autocomplete=""current-password"" required>

  <button class=""btn"" type=""submit"">Se connecter</button>
</form>

<p class=""muted"">Pas de compte ? <a class=""link"" href=""{{ url_for('register') }}"">Créer un compte</a></p>
{% endblock %}

"@
Write-File "templates/membres.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Espace membres</h1>

<div class=""grid-2"">
  <div class=""panel"">
    <h2>Connexion</h2>
    <p>Accéder à l’espace albums + outils internes.</p>
    <a class=""btn"" href=""{{ url_for('login') }}"">Se connecter</a>
  </div>

  <div class=""panel"">
    <h2>Inscription</h2>
    <p>Créer un compte (choix de rôle : Jeune / Responsable / KP).</p>
    <a class=""btn secondary"" href=""{{ url_for('register') }}"">Créer un compte</a>
  </div>
</div>

<div class=""callout"">
  <h3>Rôle KP / Responsable</h3>
  <p class=""muted"">
    Pour éviter les abus, les rôles <strong>KP</strong> et <strong>RESPONSABLE</strong> sont validés par un admin
    après inscription.
  </p>
</div>
{% endblock %}

"@
Write-File "templates/nous_connaitre.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Nous connaître</h1>

<div class=""content"">
  <p><strong>Tily Cergy FANDRESENA</strong> (Victoire) est un groupe scout à Cergy.</p>

  <div class=""callout"">
    <h3>Petit historique</h3>
    <p>
      Il était une fois… en 2024, à Cergy, un groupe de personnes motivées (un peu audacieuses, beaucoup enthousiastes 😄)
      a décidé de faire naître un nouveau groupe scout.
      Ainsi est né <strong>Tily Cergy FANDRESENA</strong> — <em>FANDRESENA</em> signifie « Victoire » en malgache ✨
    </p>
    <p>
      Dès le début, le groupe a été et reste <strong>une section vivante de la FPMA Cergy</strong>,
      avec l’envie de proposer aux jeunes un espace de croissance, de service et de fraternité,
      enraciné dans la foi chrétienne.
    </p>
    <p>
      Pour bien démarrer l’aventure, le groupe a d’abord été <strong>affilié à Tily France</strong>.
      Puis, en 2025, grande étape et immense joie 🥳 : intégration au sein de l’<strong>EEUdF</strong>.
    </p>
  </div>

  <h2>Nos branches</h2>
  <ul>
    <li><strong>Jeunes</strong> (enfants & ados)</li>
    <li><strong>Encadrants</strong> (responsables)</li>
    <li><strong>Équipe de groupe / KP</strong> (membres du bureau)</li>
  </ul>

  <h2>Envie de nous rejoindre ?</h2>
  <p>
    Passe par l’<a class=""link"" href=""{{ url_for('membres') }}"">Espace membres</a> pour créer un compte,
    ou contacte-nous (bloc “Contact” en bas de page).
  </p>
</div>
{% endblock %}

"@
Write-File "templates/nous_soutenir.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Nous soutenir</h1>

<div class=""content"">
  <p class=""lead"">
    Votre don aide à rendre les activités accessibles : matériel, transports, formations, camps, actions solidaires.
  </p>

  <div class=""grid-2"">
    <div class=""panel"">
      <h2>Don (lien externe)</h2>
      <p class=""muted"">Tu pourras remplacer ce lien quand tu seras prêt.</p>
      {% if external_url %}
        <a class=""btn"" href=""{{ external_url }}"" target=""_blank"" rel=""noopener"">Faire un don (lien)</a>
      {% else %}
        <button class=""btn secondary"" disabled>Lien de don à venir</button>
      {% endif %}
    </div>

    <div class=""panel"">
      <h2>Don par carte (Stripe)</h2>
      <p class=""muted"">Paiement sécurisé via Stripe Checkout (à activer en ajoutant les clés Stripe dans Render/.env).</p>

      <form method=""post"" action=""{{ url_for('donation_checkout') }}"" class=""don-form"">
        <label>Montant (en €)</label>
        <input type=""number"" name=""amount_eur"" min=""1"" max=""5000"" value=""10"" required />
        <button class=""btn"" type=""submit"">Payer en ligne</button>
      </form>

      {% if not stripe_public_key %}
        <p class=""muted"">⚠️ Stripe n’est pas configuré (STRIPE_PUBLIC_KEY/STRIPE_SECRET_KEY).</p>
      {% endif %}
    </div>
  </div>

  <div class=""callout"">
    <h3>Transparence & confiance</h3>
    <ul>
      <li>Les dons servent au fonctionnement et aux activités éducatives du groupe.</li>
      <li>Le budget est suivi par l’équipe (KP) et l’association.</li>
      <li>Des reçus fiscaux dépendent du canal utilisé, selon configuration.</li>
    </ul>
  </div>
</div>
{% endblock %}

"@
Write-File "templates/register.html" @"
{% extends ""base.html"" %}
{% block content %}
<h1>Créer un compte</h1>

<form method=""post"" class=""form"">
  <label>Login</label>
  <input name=""username"" autocomplete=""username"" required>

  <label>Mot de passe (8 caractères minimum)</label>
  <input name=""password"" type=""password"" autocomplete=""new-password"" required minlength=""8"">

  <label>Rôle demandé</label>
  <select name=""role"">
    <option value=""JEUNE"">Enfant / Ado (Jeune membre)</option>
    <option value=""RESPONSABLE"">RESPONSABLE (encadrant)</option>
    <option value=""KP"">KP (membre du bureau)</option>
  </select>

  <button class=""btn"" type=""submit"">Créer</button>
</form>

<p class=""muted"">Déjà un compte ? <a class=""link"" href=""{{ url_for('login') }}"">Connexion</a></p>
{% endblock %}

"@
Write-Host "OK ✅ Projet généré."
Write-Host "Lancer en local:"
Write-Host "  py -3.12 -m venv .venv"
Write-Host "  .venv\Scripts\activate"
Write-Host "  pip install -r requirements.txt"
Write-Host "  copy .env.example .env"
Write-Host "  python app.py"
