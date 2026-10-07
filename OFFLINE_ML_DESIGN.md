# Offline ML design

## No cloud dependency

The image ML stage uses Vision's on-device image feature-print model. ATLAS does not download a model or send an image to a remote service.

## Candidate gating

Vision is not run on every possible image pair. The existing pHash/dHash/grid signatures first narrow candidates. This keeps large scans practical.

## Local learning

`OfflinePairModel.json` contains a small logistic classifier trained locally from:

- high-confidence automatic duplicate matches;
- explicit NOT DUPLICATE user corrections.

It learns only from evidence available on the Mac. It is consulted only for ambiguous image candidates and cannot override a stored user veto.

## Safety rule

ML is a supporting signal, not proof. Exact equality and deterministic content signatures remain stronger. If evidence is insufficient, the item remains Uncompared rather than being promoted to Duplicate.
