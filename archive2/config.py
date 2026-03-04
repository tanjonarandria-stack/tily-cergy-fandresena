import os

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
DEFAULT_SQLITE = "sqlite:///" + os.path.join(BASE_DIR, "instance", "app.db").replace("\\", "/")

class Config:
    SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-change-me")
    SQLALCHEMY_DATABASE_URI = os.getenv("DATABASE_URL", DEFAULT_SQLITE).replace("postgres://", "postgresql://")
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    UPLOAD_FOLDER = os.getenv("UPLOAD_FOLDER", "static/uploads")
    MAX_CONTENT_LENGTH = 10 * 1024 * 1024  # 10MB

    STRIPE_SECRET_KEY = os.getenv("STRIPE_SECRET_KEY", "")
    STRIPE_PUBLIC_KEY = os.getenv("STRIPE_PUBLIC_KEY", "")
    DONATION_EXTERNAL_URL = os.getenv("DONATION_EXTERNAL_URL", "")
    BASE_URL = os.getenv("BASE_URL", "http://localhost:5000")

    CLOUDINARY_CLOUD_NAME = os.getenv("CLOUDINARY_CLOUD_NAME", "")
    CLOUDINARY_API_KEY = os.getenv("CLOUDINARY_API_KEY", "")
    CLOUDINARY_API_SECRET = os.getenv("CLOUDINARY_API_SECRET", "")
    CLOUDINARY_FOLDER = os.getenv("CLOUDINARY_FOLDER", "tily-cergy-fandresena")

    CONTACT_TO_EMAIL = os.getenv("CONTACT_TO_EMAIL", "")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USER)
SMTP_TLS = os.getenv("SMTP_TLS", "true").lower() in ("1", "true", "yes", "y")