import os
import logging

from flask import Flask, render_template, request, redirect, url_for, flash, current_app
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from werkzeug.utils import secure_filename
from werkzeug.middleware.proxy_fix import ProxyFix

import stripe
import cloudinary
import cloudinary.uploader

from config import Config
from models import db, User, NewsPost, Album, Photo, ContactMessage

ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "webp"}


def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def save_uploaded_image(file_storage, default_subfolder: str = "uploads"):
    """Save image locally or to Cloudinary. Returns (url, public_id)."""
    if not file_storage or file_storage.filename == "":
        return ("", "")
    if not allowed_file(file_storage.filename):
        return ("", "")

    cfg = current_app.config

    # Cloudinary if configured
    if cfg.get("CLOUDINARY_CLOUD_NAME") and cfg.get("CLOUDINARY_API_KEY") and cfg.get("CLOUDINARY_API_SECRET"):
        folder = f"{cfg.get('CLOUDINARY_FOLDER','tily-cergy-fandresena')}/{default_subfolder}"
        res = cloudinary.uploader.upload(file_storage, folder=folder, resource_type="image")
        url = res.get("secure_url") or res.get("url") or ""
        public_id = res.get("public_id") or ""
        return (url, public_id)

    # Local fallback
    upload_folder = cfg["UPLOAD_FOLDER"]
    os.makedirs(upload_folder, exist_ok=True)

    filename = secure_filename(file_storage.filename)
    save_path = os.path.join(upload_folder, filename)

    i = 1
    base, ext = os.path.splitext(filename)
    while os.path.exists(save_path):
        filename = f"{base}-{i}{ext}"
        save_path = os.path.join(upload_folder, filename)
        i += 1

    file_storage.save(save_path)
    return (f"/{upload_folder}/{filename}", "")


def delete_uploaded_image(url: str, public_id: str = ""):
    """Best-effort delete."""
    cfg = current_app.config

    # Cloudinary
    try:
        if public_id and cfg.get("CLOUDINARY_CLOUD_NAME"):
            cloudinary.uploader.destroy(public_id, resource_type="image")
            return
    except Exception:
        current_app.logger.exception("Cloudinary delete failed")

    # Local fallback
    try:
        if url.startswith("/"):
            path = url.lstrip("/")
            if path.startswith("static/") and os.path.exists(path):
                os.remove(path)
    except Exception:
        current_app.logger.exception("Local file delete failed")


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    # Render / reverse proxy (important)
    # so url_for() + HTTPS work correctly behind Render proxy
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    # Logging
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))

    # Secure cookies in production
    is_prod = os.getenv("ENV", "").lower() == "production" or os.getenv("FLASK_ENV", "").lower() == "production"
    if is_prod:
        app.config.update(
            SESSION_COOKIE_SECURE=True,
            REMEMBER_COOKIE_SECURE=True,
            SESSION_COOKIE_SAMESITE="Lax",
            REMEMBER_COOKIE_SAMESITE="Lax",
        )

    # Ensure folders
    os.makedirs("instance", exist_ok=True)
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    # DB
    db.init_app(app)

    # Login
    login_manager = LoginManager()
    login_manager.login_view = "login"
    login_manager.init_app(app)

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    # Stripe
    stripe.api_key = app.config.get("STRIPE_SECRET_KEY", "")

    # Cloudinary config (optional)
    if app.config.get("CLOUDINARY_CLOUD_NAME") and app.config.get("CLOUDINARY_API_KEY") and app.config.get("CLOUDINARY_API_SECRET"):
        cloudinary.config(
            cloud_name=app.config["CLOUDINARY_CLOUD_NAME"],
            api_key=app.config["CLOUDINARY_API_KEY"],
            api_secret=app.config["CLOUDINARY_API_SECRET"],
            secure=True,
        )

    # Create tables only if explicitly enabled (recommended: do it once, then disable)
    with app.app_context():
        auto_create = os.getenv("AUTO_CREATE_DB", "false").lower() in ("1", "true", "yes", "y")
        if auto_create:
            db.create_all()

        # Seed admin (only if tables exist; otherwise app still starts)
        try:
            admin_user = os.getenv("INIT_ADMIN_USER")
            admin_pass = os.getenv("INIT_ADMIN_PASS")
            if admin_user and admin_pass:
                exists = User.query.filter_by(username=admin_user.lower()).first()
                if not exists:
                    u = User(username=admin_user.lower(), role="ADMIN", role_validated=True)
                    u.set_password(admin_pass)
                    db.session.add(u)
                    db.session.commit()
                    app.logger.info("Initial admin created.")
        except Exception:
            app.logger.exception("Admin seed skipped (tables not ready).")

    # ---------------- PUBLIC ----------------
    @app.get("/")
    def home():
        latest = NewsPost.query.order_by(NewsPost.created_at.desc()).limit(3).all()
        return render_template("home.html", latest=latest)

    @app.get("/actus")
    def actus():
        posts = NewsPost.query.order_by(NewsPost.created_at.desc()).all()
        return render_template("actus.html", posts=posts)

    @app.get("/nous-connaitre")
    def nous_connaitre():
        return render_template("nous_connaitre.html")

    @app.get("/nous-soutenir")
    def nous_soutenir():
        return render_template(
            "nous_soutenir.html",
            stripe_public_key=app.config.get("STRIPE_PUBLIC_KEY", ""),
            external_url=app.config.get("DONATION_EXTERNAL_URL", ""),
        )

    @app.route("/contact", methods=["GET", "POST"])
    def contact():
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            email = request.form.get("email", "").strip()
            subject = request.form.get("subject", "").strip()
            message = request.form.get("message", "").strip()

            if not name or not email or not subject or not message:
                flash("Merci de remplir tous les champs.", "error")
                return redirect(url_for("contact"))

            cm = ContactMessage(name=name, email=email, subject=subject, message=message)
            db.session.add(cm)
            db.session.commit()

            flash("Message envoyé ✅ (il sera visible par l’admin).", "success")
            return redirect(url_for("contact"))

        return render_template("contact.html")

    # ---------------- AUTH ----------------
    @app.route("/register", methods=["GET", "POST"])
    def register():
        if request.method == "POST":
            username = request.form.get("username", "").strip().lower()
            password = request.form.get("password", "")
            role_choice = request.form.get("role", "JEUNE")

            if not username or not password:
                flash("Merci de remplir tous les champs.", "error")
                return redirect(url_for("register"))

            if len(password) < 8:
                flash("Mot de passe trop court (8 caractères minimum).", "error")
                return redirect(url_for("register"))

            if User.query.filter_by(username=username).first():
                flash("Ce login existe déjà.", "error")
                return redirect(url_for("register"))

            user = User(username=username)

            if role_choice == "JEUNE":
                user.role = "JEUNE"
                user.role_validated = True
            else:
                user.role = "JEUNE"
                user.role_requested = role_choice
                user.role_validated = False

            user.set_password(password)
            db.session.add(user)
            db.session.commit()

            flash("Compte créé. Si tu as demandé KP/RESPONSABLE, un admin doit valider.", "success")
            return redirect(url_for("login"))

        return render_template("register.html")

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if request.method == "POST":
            username = request.form.get("username", "").strip().lower()
            password = request.form.get("password", "")

            user = User.query.filter_by(username=username).first()
            if not user or not user.check_password(password):
                flash("Login ou mot de passe incorrect.", "error")
                return redirect(url_for("login"))

            login_user(user)
            flash("Connecté ✅", "success")
            return redirect(url_for("member_area"))

        return render_template("login.html")

    @app.get("/logout")
    @login_required
    def logout():
        logout_user()
        flash("Déconnecté.", "success")
        return redirect(url_for("home"))

    @app.route("/changer-mot-de-passe", methods=["GET", "POST"])
    @login_required
    def change_password():
        if request.method == "POST":
            old = request.form.get("old_password", "")
            new = request.form.get("new_password", "")

            if not current_user.check_password(old):
                flash("Ancien mot de passe incorrect.", "error")
                return redirect(url_for("change_password"))

            if len(new) < 8:
                flash("Nouveau mot de passe trop court (8 caractères minimum).", "error")
                return redirect(url_for("change_password"))

            current_user.set_password(new)
            db.session.commit()
            flash("Mot de passe mis à jour ✅", "success")
            return redirect(url_for("member_area"))

        return render_template("change_password.html")

    # ---------------- MEMBER AREA ----------------
    @app.get("/espace")
    @login_required
    def member_area():
        albums = Album.query.order_by(Album.created_at.desc()).all()
        return render_template("album_list.html", albums=albums)

    @app.route("/album/nouveau", methods=["GET", "POST"])
    @login_required
    def album_new():
        if not current_user.is_staff():
            flash("Accès réservé (KP/RESPONSABLE validé).", "error")
            return redirect(url_for("member_area"))

        if request.method == "POST":
            title = request.form.get("title", "").strip()
            desc = request.form.get("description", "").strip()
            consent = request.form.get("consent", "")

            if consent != "yes":
                flash("Merci de confirmer le respect du droit à l’image.", "error")
                return redirect(url_for("album_new"))

            if not title:
                flash("Titre obligatoire.", "error")
                return redirect(url_for("album_new"))

            a = Album(title=title, description=desc)
            db.session.add(a)
            db.session.commit()
            flash("Album créé ✅", "success")
            return redirect(url_for("album_view", album_id=a.id))

        return render_template("album_new.html")

    @app.route("/album/<int:album_id>", methods=["GET", "POST"])
    @login_required
    def album_view(album_id):
        album = db.session.get(Album, album_id)
        if not album:
            flash("Album introuvable.", "error")
            return redirect(url_for("member_area"))

        if request.method == "POST":
            if not current_user.is_staff():
                flash("Upload réservé (KP/RESPONSABLE validé).", "error")
                return redirect(url_for("album_view", album_id=album_id))

            file = request.files.get("photo")
            caption = request.form.get("caption", "").strip()
            consent = request.form.get("consent", "")

            if consent != "yes":
                flash("Merci de confirmer le respect du droit à l’image.", "error")
                return redirect(url_for("album_view", album_id=album_id))

            if not file or file.filename == "":
                flash("Aucun fichier sélectionné.", "error")
                return redirect(url_for("album_view", album_id=album_id))

            if not allowed_file(file.filename):
                flash("Format non autorisé (png/jpg/jpeg/webp).", "error")
                return redirect(url_for("album_view", album_id=album_id))

            image_url, public_id = save_uploaded_image(file, default_subfolder="albums")
            if not image_url:
                flash("Upload impossible.", "error")
                return redirect(url_for("album_view", album_id=album_id))

            p = Photo(album_id=album_id, file_path=image_url, caption=caption, approved=False, cloudinary_public_id=public_id)
            db.session.add(p)
            db.session.commit()

            flash("Photo ajoutée ✅", "success")
            return redirect(url_for("album_view", album_id=album_id))

        photos = Photo.query.filter_by(album_id=album_id).order_by(Photo.created_at.desc()).all()
        return render_template("album_view.html", album=album, photos=photos)

    @app.post("/album/<int:album_id>/approve")
    @login_required
    def album_approve(album_id):
        if not current_user.is_staff() and current_user.role != "ADMIN":
            flash("Accès réservé (KP/RESPONSABLE validé).", "error")
            return redirect(url_for("member_area"))

        album = db.session.get(Album, album_id)
        if not album:
            flash("Album introuvable.", "error")
            return redirect(url_for("member_area"))

        album.approved = True
        db.session.commit()
        flash("Album approuvé ✅", "success")
        return redirect(url_for("member_area"))

    @app.post("/photo/<int:photo_id>/approve")
    @login_required
    def photo_approve(photo_id):
        if not current_user.is_staff() and current_user.role != "ADMIN":
            flash("Accès réservé (KP/RESPONSABLE validé).", "error")
            return redirect(url_for("member_area"))

        photo = db.session.get(Photo, photo_id)
        if not photo:
            flash("Photo introuvable.", "error")
            return redirect(url_for("member_area"))

        photo.approved = True
        db.session.commit()
        flash("Photo approuvée ✅", "success")
        return redirect(url_for("album_view", album_id=photo.album_id))

    # ---------------- STAFF ACTUS ----------------
    @app.route("/staff/actus", methods=["GET", "POST"])
    @login_required
    def staff_actus():
        if not current_user.is_staff() and current_user.role != "ADMIN":
            flash("Accès réservé (KP/RESPONSABLE validé).", "error")
            return redirect(url_for("home"))

        if request.method == "POST":
            title = request.form.get("title", "").strip()
            content = request.form.get("content", "").strip()
            file = request.files.get("image")

            if not title or not content:
                flash("Titre + contenu obligatoires.", "error")
                return redirect(url_for("staff_actus"))

            image_path, public_id = ("", "")
            if file and file.filename:
                image_path, public_id = save_uploaded_image(file, default_subfolder="actus")

            post = NewsPost(title=title, content=content, image_path=image_path, cloudinary_public_id=public_id)
            db.session.add(post)
            db.session.commit()
            flash("Actu publiée ✅", "success")
            return redirect(url_for("actus"))

        return render_template("staff_actus.html")

    @app.post("/admin/post/<int:post_id>/delete")
    @login_required
    def delete_post(post_id):
        if current_user.role != "ADMIN":
            flash("Suppression réservée à l’admin.", "error")
            return redirect(url_for("actus"))

        post = db.session.get(NewsPost, post_id)
        if not post:
            flash("Actu introuvable.", "error")
            return redirect(url_for("actus"))

        if post.image_path:
            delete_uploaded_image(post.image_path, getattr(post, "cloudinary_public_id", "") or "")

        db.session.delete(post)
        db.session.commit()
        flash("Actu supprimée ✅", "success")
        return redirect(url_for("actus"))

    @app.post("/photo/<int:photo_id>/delete")
    @login_required
    def delete_photo(photo_id):
        if not current_user.is_staff() and current_user.role != "ADMIN":
            flash("Suppression réservée (KP/RESPONSABLE validé).", "error")
            return redirect(url_for("member_area"))

        photo = db.session.get(Photo, photo_id)
        if not photo:
            flash("Photo introuvable.", "error")
            return redirect(url_for("member_area"))

        album_id = photo.album_id
        delete_uploaded_image(photo.file_path, getattr(photo, "cloudinary_public_id", "") or "")
        db.session.delete(photo)
        db.session.commit()
        flash("Photo supprimée ✅", "success")
        return redirect(url_for("album_view", album_id=album_id))

    # ---------------- STRIPE DONATION ----------------
    @app.post("/don/checkout")
    def donation_checkout():
        try:
            amount_eur = int(request.form.get("amount_eur", "10"))
        except ValueError:
            amount_eur = 10
        amount_eur = max(1, min(amount_eur, 5000))

        if not app.config.get("STRIPE_SECRET_KEY"):
            flash("Stripe n’est pas configuré (STRIPE_SECRET_KEY).", "error")
            return redirect(url_for("nous_soutenir"))

        session = stripe.checkout.Session.create(
            mode="payment",
            payment_method_types=["card"],
            line_items=[{
                "price_data": {
                    "currency": "eur",
                    "product_data": {"name": "Don – Tily Cergy Fandresena (EEUdF Cergy)"},
                    "unit_amount": amount_eur * 100,
                },
                "quantity": 1,
            }],
            success_url=f"{app.config['BASE_URL']}{url_for('don_success')}",
            cancel_url=f"{app.config['BASE_URL']}{url_for('nous_soutenir')}",
        )
        return redirect(session.url, code=303)

    @app.get("/don/merci")
    def don_success():
        return render_template("don_success.html")

    # Basic error pages
    @app.errorhandler(404)
    def not_found(e):
        return render_template("404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        app.logger.exception("Server error")
        return render_template("500.html"), 500

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=True)