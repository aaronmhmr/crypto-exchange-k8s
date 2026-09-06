"""Health endpoints for the Kubernetes probes.

/healthz/ is a liveness check: it must never touch the database, or a
transient DB blip would cause every pod to be restarted at once.
/readyz/ is a readiness check: it verifies the app can actually serve
traffic, which for this app means the database is reachable.
"""
from django.db import connection
from django.http import HttpResponse, HttpResponseServerError


def healthz(request):
    return HttpResponse("ok")


def readyz(request):
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
    except Exception as exc:  # noqa: BLE001 -- deliberately broad: any DB failure means not-ready
        return HttpResponseServerError(f"database not ready: {exc}")
    return HttpResponse("ok")
