"""
Never Down — Reconciliación de failback (Firestore → DynamoDB).

Mientras el tráfico estuvo en GCP, pudieron entrar pedidos nuevos, o borrarse
pedidos existentes, sin que eso llegara a AWS (la réplica en caliente de la
Fase 3 es unidireccional AWS→GCP). Antes de volver el tráfico a AWS, este
handler:
  - ALTAS: copia (upsert) todo lo que sigue vivo en Firestore hacia DynamoDB.
  - BAJAS: aplica los tombstones de "never-down-deletions" (pedidos borrados
    mientras GCP era primario) borrándolos también en DynamoDB.

Usa la misma autenticación WIF que la Lambda de sync (mismo rol de IAM).
"""

import os
from decimal import Decimal

import boto3
from google.cloud import firestore

PROJECT     = os.environ["GCP_PROJECT"]
COLLECTION  = os.environ.get("COLLECTION", "never-down-orders")
DELETIONS   = os.environ.get("DELETIONS_COLLECTION", "never-down-deletions")
TABLE_NAME  = os.environ.get("TABLE_NAME", "never-down-orders")

_db        = firestore.Client(project=PROJECT)
_col       = _db.collection(COLLECTION)
_deletions = _db.collection(DELETIONS)
_table     = boto3.resource("dynamodb").Table(TABLE_NAME)


def _to_dynamo(v):
    """Firestore devuelve float; DynamoDB necesita Decimal."""
    if isinstance(v, float):
        return Decimal(str(v))
    if isinstance(v, list):
        return [_to_dynamo(x) for x in v]
    if isinstance(v, dict):
        return {k: _to_dynamo(x) for k, x in v.items()}
    return v


def handler(event, context):
    # --- Altas: todo lo que sigue vivo en Firestore se copia a DynamoDB ---
    copied = []
    for doc in _col.stream():
        data = doc.to_dict()
        item = {k: _to_dynamo(v) for k, v in data.items()}
        item["id"] = str(doc.id)
        item["reconciled_from"] = "gcp-firestore"
        _table.put_item(Item=item)
        copied.append(item["id"])
        print(f"[RECONCILE] alta: pedido {item['id']} ({data.get('customer', '?')}) → DynamoDB")

    # --- Bajas: tombstones de pedidos borrados mientras GCP era primario ---
    deleted = []
    for tomb in _deletions.stream():
        order_id = tomb.id
        _table.delete_item(Key={"id": order_id})
        deleted.append(order_id)
        print(f"[RECONCILE] baja: pedido {order_id} borrado en DynamoDB (tombstone)")
        tomb.reference.delete()  # limpiar el tombstone ya procesado

    return {"reconciled": len(copied), "ids": copied, "deleted": deleted}
