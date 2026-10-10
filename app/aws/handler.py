"""
Never Down — Café Quetzal ☕ (AWS Lambda, cloud primario)

Sistema de pedidos de una cafetería. La misma lógica está replicada en
GCP Cloud Run (app/gcp/main.py). Cada pedido guarda qué nube lo registró
(served_by) para que en el failover en vivo se vea el cambio AWS→GCP.

Rutas:
  GET  /health          -> estado + served_by
  GET  /menu            -> menú de la cafetería
  GET  /orders          -> lista de pedidos
  POST /orders          -> crea pedido {"customer": "...", "items":[{"sku","qty"}]}
  GET  /orders/{id}     -> obtiene un pedido
"""

import json
import os
import time
import uuid
from decimal import Decimal

import boto3

TABLE_NAME = os.environ.get("TABLE_NAME", "never-down-orders")
SERVED_BY = os.environ.get("SERVED_BY", "aws-lambda")

_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(TABLE_NAME)

# Menú de Café Quetzal (precios en USD)
MENU = {
    "esp":  {"name": "Espresso",   "price": Decimal("1.50")},
    "amer": {"name": "Americano",  "price": Decimal("2.00")},
    "cap":  {"name": "Cappuccino", "price": Decimal("2.50")},
    "lat":  {"name": "Latte",      "price": Decimal("2.75")},
    "moc":  {"name": "Mocha",      "price": Decimal("3.00")},
    "cold": {"name": "Cold Brew",  "price": Decimal("3.25")},
}


class _Enc(json.JSONEncoder):
    """DynamoDB devuelve Decimal; lo serializamos como número/str legible."""

    def default(self, o):
        if isinstance(o, Decimal):
            return float(o)
        return super().default(o)


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
            "X-Served-By": SERVED_BY,
        },
        "body": json.dumps(body, cls=_Enc),
    }


def _menu():
    items = [{"sku": sku, **v} for sku, v in MENU.items()]
    return _resp(200, {"served_by": SERVED_BY, "cafe": "Café Quetzal", "menu": items})


def _list_orders():
    result = _table.scan(Limit=50)
    orders = sorted(result.get("Items", []), key=lambda x: x.get("created_at", 0), reverse=True)
    return _resp(200, {"served_by": SERVED_BY, "count": len(orders), "orders": orders})


def _create_order(payload):
    customer = (payload or {}).get("customer", "Anónimo")
    raw_items = (payload or {}).get("items", [])
    if not raw_items:
        return _resp(400, {"error": "el pedido no tiene items"})

    line_items = []
    total = Decimal("0")
    for li in raw_items:
        sku = li.get("sku")
        qty = int(li.get("qty", 1))
        if sku not in MENU or qty < 1:
            return _resp(400, {"error": f"item inválido: {sku}"})
        product = MENU[sku]
        subtotal = product["price"] * qty
        total += subtotal
        line_items.append({"sku": sku, "name": product["name"], "qty": qty, "subtotal": subtotal})

    order = {
        "id": str(uuid.uuid4())[:8],
        "customer": str(customer)[:80],
        "items": line_items,
        "total": total,
        "status": "recibido",
        "created_at": int(time.time()),
        "served_by": SERVED_BY,
    }
    _table.put_item(Item=order)
    return _resp(201, {"served_by": SERVED_BY, "order": order})


def _get_order(order_id):
    result = _table.get_item(Key={"id": order_id})
    order = result.get("Item")
    if not order:
        return _resp(404, {"error": "pedido no encontrado"})
    return _resp(200, {"served_by": SERVED_BY, "order": order})


def _delete_order(order_id):
    _table.delete_item(Key={"id": order_id})
    return _resp(200, {"served_by": SERVED_BY, "deleted": order_id})


def handler(event, context):
    """Entry point del Lambda. API Gateway HTTP API (payload v2)."""
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")

    # Preflight CORS: el navegador manda OPTIONS antes de POST/DELETE cross-origin.
    # Debe responder 2xx o el navegador bloquea la petición real.
    if method == "OPTIONS":
        return _resp(200, {"ok": True})

    try:
        if path == "/" or path == "":
            return _resp(200, {
                "cafe": "Café Quetzal ☕",
                "tagline": "Never Down — pedidos que sobreviven una caída de nube",
                "served_by": SERVED_BY,
                "status": "ok",
                "endpoints": {
                    "GET /health": "estado",
                    "GET /menu": "menú",
                    "GET /orders": "lista de pedidos",
                    "POST /orders": "crear pedido {customer, items:[{sku, qty}]}",
                    "GET /orders/{id}": "detalle de pedido",
                },
            })
        if path == "/health":
            return _resp(200, {"status": "ok", "served_by": SERVED_BY, "ts": int(time.time())})
        if path == "/menu" and method == "GET":
            return _menu()
        if path == "/orders" and method == "GET":
            return _list_orders()
        if path == "/orders" and method == "POST":
            return _create_order(json.loads(event.get("body") or "{}"))
        if path.startswith("/orders/") and method == "GET":
            return _get_order(path.split("/orders/", 1)[1])
        if path.startswith("/orders/") and method == "DELETE":
            return _delete_order(path.split("/orders/", 1)[1])
        return _resp(404, {"error": "ruta no encontrada", "path": path})
    except Exception as exc:  # noqa: BLE001 — en el demo queremos ver el error
        return _resp(500, {"error": "internal", "detail": str(exc), "served_by": SERVED_BY})
