"""
Never Down — Lambda de replicación DynamoDB → Firestore.

Disparada por DynamoDB Streams. Replica cada cambio de la tabla de pedidos a
Firestore (GCP), para que el warm standby tenga los datos ANTES de una caída.

Autenticación a GCP: Workload Identity Federation (sin llaves). El cliente de
Firestore usa GOOGLE_APPLICATION_CREDENTIALS=gcp-cred-config.json, que federa el
rol de esta Lambda a una service account de GCP vía STS.

Eventos del stream:
  INSERT / MODIFY -> upsert del pedido en Firestore
  REMOVE          -> borra el pedido en Firestore
"""

import os
from decimal import Decimal

from boto3.dynamodb.types import TypeDeserializer
from google.cloud import firestore

PROJECT = os.environ["GCP_PROJECT"]
COLLECTION = os.environ.get("COLLECTION", "never-down-orders")

_db = firestore.Client(project=PROJECT)
_col = _db.collection(COLLECTION)
_deser = TypeDeserializer()


def _clean(v):
    """Convierte tipos de DynamoDB (Decimal) a tipos nativos para Firestore."""
    if isinstance(v, Decimal):
        return int(v) if v % 1 == 0 else float(v)
    if isinstance(v, list):
        return [_clean(x) for x in v]
    if isinstance(v, dict):
        return {k: _clean(x) for k, x in v.items()}
    return v


def _deserialize_image(image):
    return {k: _clean(_deser.deserialize(val)) for k, val in image.items()}


def handler(event, context):
    replicated = 0
    for rec in event.get("Records", []):
        name = rec.get("eventName")
        ddb = rec.get("dynamodb", {})
        order_id = _clean(_deser.deserialize(ddb["Keys"]["id"]))

        if name in ("INSERT", "MODIFY"):
            image = ddb.get("NewImage")
            if image:
                doc = _deserialize_image(image)
                _col.document(str(order_id)).set(doc)
                replicated += 1
                print(f"[SYNC] {name} pedido {order_id} → Firestore")
        elif name == "REMOVE":
            _col.document(str(order_id)).delete()
            replicated += 1
            print(f"[SYNC] REMOVE pedido {order_id} → Firestore")

    return {"replicated": replicated, "total": len(event.get("Records", []))}
