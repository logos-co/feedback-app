# feedback_ui

The Basecamp **Feedback app**: send feedback on Basecamp from inside Basecamp. Two forms, a quick
report (title, topic, message, optional contact) and a short questionnaire. Built with the Logos
design system; responsive at 390 / 700 / 1280.

Each response is sealed by **feedback_core** (anonymous `crypto_box_seal` to the Feedback Desk) and
published over **Logos Messaging**. The sender stays anonymous; only the Desk can open a response.

Part of a pair:
- **feedback-app** (this repo): the QML UI (`feedback_ui`).
- **feedback_core**: the C++ crypto core it depends on.

The always-on collector (Feedback Desk) and the design spec live in `xAlisher/feedback-bc`.

## Network

The app publishes on the **Logos Messaging testnet** (logos.test, cluster 2) with the preset name left
empty and the network spelled out (`net.js`): delivery_module turns its RLN send gate on for the preset
*name* `logos.test`, so this keeps sending without an RLN membership until relay validation turns on
(v0.4 or later).

Basecamp shares one delivery node between apps, and the first app to create it sets its config. If
another app already started it, Feedback reads the node's cluster (from its ENR) and `rlnState`, and
tells the user to restart Basecamp and open Feedback first when that node is on another network or
RLN-gated without a membership. A response counts as sent only when delivery confirms it
(`messagePropagated` / `messageSent`); anything unconfirmed stays queued or is shown as unconfirmed.

## Tests

`node --test test/` checks the network logic in `net.js` against values captured from live probes.

## Dependencies

- `feedback_core` (sealing)
- `delivery_module` (Logos Messaging)

## Deep link

Opens via the `feedback.open` intent carrying `{ topic }`, so the home "Share Feedback" tile (and
other apps) can open the app with a topic preselected.

## Files

- `Main.qml` — the view
- `net.js` — network config, node detection and send state (no Qt APIs; tested in `test/`)
- `metadata.json` / `manifest.json` — the `ui_qml` module descriptor (`pluginType: qml`)
- `feedback.png` — tile icon

## Notes

Today the UI talks to core modules directly from QML (`logos.callModule`). A planned follow-up moves
the connect/seal/send orchestration into `feedback_core` and exposes a single `submitFeedback()` to
QML, so the UI only calls its own backend. Tracked with the rest of the Feedback work in
logos-co/ecosystem#273.
