from django.contrib import admin
from django.urls import path, include
from . import health


urlpatterns = [
    path("healthz/", health.healthz, name="healthz"),
    path("readyz/", health.readyz, name="readyz"),
    path("admin/", admin.site.urls),
    path("", include('dashboard.urls')),
    path("", include('users.urls')),
    path("", include('trading.urls')),
]
