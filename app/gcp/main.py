"""
Never Down — Café Quetzal ☕ (GCP Cloud Run, warm standby)

Misma lógica que la Lambda de AWS (app/aws/handler.py) pero sobre Firestore.
Tras el failover, la MISMA URL sigue tomando pedidos — ahora desde GCP.

Rutas:
  GET  /health          -> estado + served_by
  GET  /menu            -> menú de la cafetería
  GET  /orders          -> lista de pedidos
  POST /orders          -> crea pedido {"customer": "...", "items":[{"sku","qty"}]}
  GET  /orders/<id>     -> obtiene un pedido
"""

import os
import time
import uuid

from flask import Flask, jsonify, request, send_from_directory
from google.cloud import firestore

SERVED_BY = os.environ.get("SERVED_BY", "gcp-cloud-run")
COLLECTION = os.environ.get("COLLECTION", "never-down-orders")
WEB_DIR = os.environ.get("WEB_DIR", "web")

# Rutas reservadas para la API (no se sirven como archivos estáticos)
_API_PATHS = {"health", "menu", "orders"}

# Menú de Café Quetzal (precios en USD) — idéntico al de AWS
MENU = {
    "esp":  {"name": "Espresso",   "price": 1.50},
    "amer": {"name": "Americano",  "price": 2.00},
    "cap":  {"name": "Cappuccino", "price": 2.50},
    "lat":  {"name": "Latte",      "price": 2.75},
    "moc":  {"name": "Mocha",      "price": 3.00},
    "cold": {"name": "Cold Brew",  "price": 3.25},
}

# Tombstones: cuando se borra un pedido acá (GCP standby), dejamos rastro para
# que la reconciliación de failback (GCP→AWS) también borre en DynamoDB.
DELETIONS_COLLECTION = os.environ.get("DELETIONS_COLLECTION", "never-down-deletions")

app = Flask(__name__, static_folder=None)
_db = firestore.Client()
_col = _db.collection(COLLECTION)
_deletions = _db.collection(DELETIONS_COLLECTION)


def _hdr(resp):
    resp.headers["Cache-Control"] = "no-cache"
    resp.headers["X-Served-By"] = SERVED_BY
    return resp


@app.after_request
def _cors(resp):
    # CORS para que el front (cafequetzal) llame a la API (cafeapi) en otro origen,
    # incluido el preflight OPTIONS del método DELETE.
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "content-type"
    return resp


# ---------- Frontend estático (Cloud Run sirve el front en "/") ----------
@app.get("/")
def index():
    return _hdr(send_from_directory(WEB_DIR, "index.html"))


@app.get("/<path:filename>")
def static_files(filename):
    if filename.split("/")[0] in _API_PATHS:
        return _hdr(jsonify(error="ruta no encontrada")), 404
    return _hdr(send_from_directory(WEB_DIR, filename))


@app.get("/health")
def health():
    return _hdr(jsonify(status="ok", served_by=SERVED_BY, ts=int(time.time())))


@app.get("/menu")
def menu():
    items = [{"sku": sku, **v} for sku, v in MENU.items()]
    return _hdr(jsonify(served_by=SERVED_BY, cafe="Café Quetzal", menu=items))


@app.get("/orders")
def list_orders():
    docs = _col.order_by("created_at", direction=firestore.Query.DESCENDING).limit(50).stream()
    orders = [d.to_dict() for d in docs]
    return _hdr(jsonify(served_by=SERVED_BY, count=len(orders), orders=orders))


@app.post("/orders")
def create_order():
    payload = request.get_json(silent=True) or {}
    customer = payload.get("customer", "Anónimo")
    raw_items = payload.get("items", [])
    if not raw_items:
        return _hdr(jsonify(error="el pedido no tiene items")), 400

    line_items = []
    total = 0.0
    for li in raw_items:
        sku = li.get("sku")
        qty = int(li.get("qty", 1))
        if sku not in MENU or qty < 1:
            return _hdr(jsonify(error=f"item inválido: {sku}")), 400
        product = MENU[sku]
        subtotal = round(product["price"] * qty, 2)
        total = round(total + subtotal, 2)
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
    _col.document(order["id"]).set(order)
    return _hdr(jsonify(served_by=SERVED_BY, order=order)), 201


@app.get("/orders/<order_id>")
def get_order(order_id):
    doc = _col.document(order_id).get()
    if not doc.exists:
        return _hdr(jsonify(error="pedido no encontrado")), 404
    return _hdr(jsonify(served_by=SERVED_BY, order=doc.to_dict()))


@app.delete("/orders/<order_id>")
def delete_order(order_id):
    _col.document(order_id).delete()
    # Tombstone: registra el borrado para que el failback (GCP→AWS) también
    # borre este pedido en DynamoDB, y no "reviva" al reconciliar.
    _deletions.document(order_id).set({"id": order_id, "deleted_at": int(time.time())})
    return _hdr(jsonify(served_by=SERVED_BY, deleted=order_id))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
